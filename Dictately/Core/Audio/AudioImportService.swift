import AVFoundation
import Foundation

/// 文件转写音频服务（TASK-150）：导入文件时长探测 + 长音频统一切片（TASK-151）。
///
/// 2026-10-25 分段管线改版：任意白名单源一律经 `prepareSegments` 统一转成
/// 16k/mono/16bit WAV 分段（本地与 API 共用同一路径）——消灭直传/转码二路分支
/// （m4a 原直传本地通道依赖系统 ffmpeg，App 环境必失败；mp3 直传 worker 走
/// miniaudio 纯解码 11 分钟要 34s）。写入用 AVAudioFile 逐段落盘，内存有界
/// （单段缓冲 ≤~6MB，小时级长音频不整段驻留）。
enum AudioImportService {
    /// 转码目标格式（与 App 录音同规格：16kHz/单声道/16bit 小端 PCM WAV）。
    static let targetSampleRate: Double = 16_000

    /// 支持的音频扩展名白名单（第一期音频，2026-10-24 用户裁决：视频 mp4/mov 之后再做）。
    static let allowedExtensions: Set<String> = ["mp3", "wav", "m4a"]

    /// 文件是否在白名单内（拖放/fileImporter 过滤 + 不合格式 Toast）。
    static func isAllowed(url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 探测时长（毫秒）。读不出（损坏文件/特殊流）返回 nil——UI 显示「—」，不阻断导入。
    static func probeDurationMs(url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int(seconds * 1000)
    }

    /// 文件字节数（失败返回 nil；文件行 meta 与入库用）。
    static func fileSizeBytes(url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    /// 转码为 16k/mono/16bit WAV（API 侧 m4a 通道；mp3/wav 不经此）。
    /// - Parameters:
    ///   - source: 源音频文件（AVAudioFile 可读封装）。
    ///   - destination: 产物 WAV 路径（临时目录；调用方转写后清理）。
    static func convertToWAV16kMono(source: URL, destination: URL) throws {
        let srcFile = try AVAudioFile(forReading: source)
        let srcFormat = srcFile.processingFormat
        guard srcFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate,
                channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: srcFormat, to: outFormat) else {
            throw ConversionError.unreadableFormat
        }

        // AVAudioFile 流式写 WAV（标准 PCM 头由 AVFoundation 维护，帧数据逐段落盘）
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outFile = try AVAudioFile(
            forWriting: destination, settings: outSettings,
            commonFormat: .pcmFormatInt16, interleaved: true)

        // 输入块：按需从源文件顺序读块（同一 convert 调用内可被多次拉取）
        let readChunkFrames: AVAudioFrameCount = 65_536
        var readerDone = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if readerDone {
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: readChunkFrames) else {
                readerDone = true
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try srcFile.read(into: buf)
            } catch {
                readerDone = true
                outStatus.pointee = .endOfStream
                return nil
            }
            guard buf.frameLength > 0 else {
                readerDone = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return buf
        }

        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: readChunkFrames) else {
                throw ConversionError.unreadableFormat
            }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError, withInputFrom: inputBlock)
            if status == .error || conversionError != nil {
                throw ConversionError.decodeFailed(conversionError?.localizedDescription ?? "")
            }
            if out.frameLength > 0 {
                try outFile.write(from: out)
            }
            if status == .endOfStream || (status == .inputRanDry && out.frameLength == 0) {
                break
            }
        }
    }

    enum ConversionError: Error, CustomStringConvertible {
        case unreadableFormat
        case decodeFailed(String)

        var description: String {
            switch self {
            case .unreadableFormat: return "音频格式无法解码"
            case .decodeFailed(let detail): return "音频转码失败（\(detail)）"
            }
        }
    }

    // MARK: - 长音频分段（TASK-151 统一切片管线）

    /// 能量吸附搜索窗（目标切点前 3s）与探测子窗（200ms）长度，帧数按 16k 折算。
    private static let snapSearchFrames = Int(3.0 * 16_000)
    private static let snapProbeFrames = Int(0.2 * 16_000)
    /// 能量扫描步进（≈6ms）——控制逐帧平方和的计算量。
    private static let snapStrideFrames = 100

    /// 长音频分段：任意白名单源 → 16k/mono/16bit WAV 段文件序列（`seg-001.wav…`）。
    ///
    /// - Parameters:
    ///   - source: 源音频文件（AVAudioFile 可读封装；mp3/m4a 由 AVFoundation 解码，
    ///     不依赖系统 ffmpeg）。
    ///   - directory: 段文件落盘目录（自动创建；清理由调用方负责）。
    ///   - segmentSeconds: 目标段长（默认 180s；实测切片粒度下转写质量与 API 相当，
    ///     见 docs/test-long-audio/report.md）。
    /// - Returns: 段文件 URL（按序；尾段可短于目标段长）。样本总帧数无损。
    ///
    /// 切点吸附：目标切点前 3s 窗内找 200ms 最低能量子窗起点落刀（避开词句中腰）；
    /// 搜索窗不足（短段/测试小段）时退化为硬切。
    static func prepareSegments(
        source: URL, directory: URL, segmentSeconds: Double
    ) throws -> [URL] {
        let srcFile = try AVAudioFile(forReading: source)
        let srcFormat = srcFile.processingFormat
        guard srcFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate,
                channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: srcFormat, to: outFormat) else {
            throw ConversionError.unreadableFormat
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let segmentFrames = max(1, Int((segmentSeconds * targetSampleRate).rounded()))
        var segmentURLs: [URL] = []
        var samples: [Int16] = [] // 当前段累积（16k mono；单段 ≤~6MB 内存有界）

        // 输入块：与 convertToWAV16kMono 同款（按需拉取源块直至 endOfStream）
        let readChunkFrames: AVAudioFrameCount = 65_536
        var readerDone = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if readerDone {
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: readChunkFrames) else {
                readerDone = true
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try srcFile.read(into: buf)
            } catch {
                readerDone = true
                outStatus.pointee = .endOfStream
                return nil
            }
            guard buf.frameLength > 0 else {
                readerDone = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return buf
        }

        func flushSegment(upTo cut: Int) throws {
            guard cut > 0 else { return }
            let name = String(format: "seg-%03d.wav", segmentURLs.count + 1)
            let url = directory.appendingPathComponent(name)
            try writeWAVFile(Array(samples.prefix(cut)), to: url, format: outFormat)
            segmentURLs.append(url)
            samples.removeFirst(cut)
        }

        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: readChunkFrames) else {
                throw ConversionError.unreadableFormat
            }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError, withInputFrom: inputBlock)
            if status == .error || conversionError != nil {
                throw ConversionError.decodeFailed(conversionError?.localizedDescription ?? "")
            }
            if out.frameLength > 0, let channel = out.int16ChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channel, count: Int(out.frameLength)))
            }
            // 段满即封段（while：一次转换块可能补足多段——极端 resample 比例时）
            while samples.count >= segmentFrames {
                let cut = snapCutIndex(in: samples, target: segmentFrames)
                try flushSegment(upTo: cut)
            }
            if status == .endOfStream || (status == .inputRanDry && out.frameLength == 0) {
                break
            }
        }
        if !samples.isEmpty { try flushSegment(upTo: samples.count) }
        return segmentURLs
    }

    /// 目标切点前搜索窗内的最低能量切点（帧索引）。搜索域 [max(probe, target-3s),
    /// target-probe]；不足（段短于探测余量）→ target（硬切）。
    private static func snapCutIndex(in samples: [Int16], target: Int) -> Int {
        let probe = snapProbeFrames
        guard samples.count >= target, target > probe * 2 else { return target }
        let lo = max(probe, target - snapSearchFrames)
        let hi = target - probe
        guard hi > lo else { return target }
        var best = target
        var bestEnergy = Double.infinity
        var index = lo
        while index <= hi {
            var energy = 0.0
            for sample in samples[index..<(index + probe)] {
                let value = Double(sample)
                energy += value * value
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = index
            }
            index += snapStrideFrames
        }
        return best
    }

    /// 样本序列 → 16k/mono/16bit WAV（标准 PCM 头由 AVFoundation 维护）。
    private static func writeWAVFile(
        _ samples: [Int16], to url: URL, format: AVAudioFormat
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        guard samples.isEmpty == false,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return // 空段不落盘（flushSegment 已以 cut > 0 拦截，双保险）
        }
        samples.withUnsafeBufferPointer { source in
            _ = buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }
}
