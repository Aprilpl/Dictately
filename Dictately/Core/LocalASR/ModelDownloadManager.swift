import Foundation
import CryptoKit

/// 模型下载会话工厂：GB 级大文件专用（不复用 NetworkSessionFactory 的
/// 60s/120s 预算——resource 超时必须放得下一次 2.5GB 下载；request 超时保留
/// 60s 只作「无字节进流」的停滞检测，正常下载中每次读到数据即重置）。
enum ModelDownloadSessionFactory {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: config)
    }
}

/// 文件树 + 直链构造的渠道接缝（单测注入 Fake；TASK-144 渠道化：直链构造从
/// 本类对 ModelScopeClient 的静态调用收编进协议，渠道差异——host/默认分支/
/// 路径编码——内聚在各客户端；ModelScope 与 HuggingFace 各自实现）。
protocol ModelFileProviding: AnyObject {
    func fetchFiles(repoID: String) async throws -> [ModelRepoFile]
    func resolveURL(repoID: String, path: String) -> URL
}

extension ModelScopeClient: ModelFileProviding {
    func resolveURL(repoID: String, path: String) -> URL {
        Self.resolveURL(repoID: repoID, path: path)
    }
}

extension HuggingFaceClient: ModelFileProviding {
    func resolveURL(repoID: String, path: String) -> URL {
        Self.resolveURL(repoID: repoID, path: path)
    }
}

/// 已安装模型的落盘清单（manifest 存在即视为已安装；记录文件表供删除/统计）。
struct ModelManifest: Equatable, Codable {
    struct FileEntry: Equatable, Codable {
        let path: String
        let size: Int64
        let sha256: String?
    }

    let repoID: String
    let downloadedAt: Date
    let files: [FileEntry]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum ModelDownloadError: Error, Equatable {
    /// SHA256 与文件树声明不符（已自动重试一次仍不符）。
    case checksumMismatch(path: String)
    /// 网络重试次数用尽。
    case networkExhausted(underlying: String)
}

/// 本地模型下载管理器（TASK-134）：App 内从 ModelScope 匿名直链下载到
/// `~/Library/Application Support/Dictately/Models/<namespace>/<model>/`
/// （数据不进 .app——写入破坏 codesign 签名且 /Applications 非保证可写，
/// 与 RequestLog 同一纪律）。
///
/// 下载策略（2026-10-11 调研定稿）：文件树 API 拿 Path/Size/Sha256 → 逐文件
/// `.part` 临时 + HTTP Range 断点续传（LFS 签名 CDN 约小时级时效，续传重走
/// resolve 拿新 302）→ 边下边算 SHA256 → 全部完成写 manifest 原子收口。
/// 取消保留 `.part`（下次续传）；网络错误每文件最多 3 次（含续传位置自动前进）。
///
/// 线程约定：状态属性按惯例只在主线程读写（AppEnvironment 同款——非 actor、
/// 主线程序列化）；下载字节流在协作线程池跑，进度/收口经 MainActor.run 回跳。
@Observable
final class ModelDownloadManager {
    /// 已安装（manifest 在盘）的 repo id 集合。
    private(set) var installedRepos: Set<String> = []
    /// 下载中进度（repo id → 0…1）。
    private(set) var downloadFractions: [String: Double] = [:]
    /// 下载失败的用户可读信息（repo id → 消息；下次启动下载时清除）。
    private(set) var failureMessages: [String: String] = [:]
    /// 各 repo 本次（进行中/失败）下载所用渠道（TASK-144：进度行/失败行显示
    /// 渠道名；成功收口清除、失败保留至下次启动下载——与 failureMessages
    /// 同生命周期）。
    private(set) var downloadChannels: [String: AppSettings.DownloadChannel] = [:]

    let modelsRoot: URL

    private let modelScopeProvider: ModelFileProviding
    private let huggingFaceProvider: ModelFileProviding
    private let session: URLSession
    private var tasks: [String: Task<Void, Never>] = [:]
    private var manifests: [String: ModelManifest] = [:]

    init(
        modelsRoot: URL,
        modelScopeProvider: ModelFileProviding = ModelScopeClient(),
        huggingFaceProvider: ModelFileProviding = HuggingFaceClient(),
        session: URLSession = ModelDownloadSessionFactory.make()
    ) {
        self.modelsRoot = modelsRoot
        self.modelScopeProvider = modelScopeProvider
        self.huggingFaceProvider = huggingFaceProvider
        self.session = session
        scanInstalled()
    }

    // MARK: - 查询

    func isInstalled(_ repoID: String) -> Bool { installedRepos.contains(repoID) }
    func isDownloading(_ repoID: String) -> Bool { downloadFractions[repoID] != nil }

    func installedDirectory(_ repoID: String) -> URL? {
        guard isInstalled(repoID) else { return nil }
        return LocalModelCatalog.directory(repoID: repoID, root: modelsRoot)
    }

    /// 已安装模型总体积（manifest 记录值求和；供状态条「占用 ≈X GB」）。
    var totalInstalledBytes: Int64 {
        manifests.values.reduce(0) { $0 + $1.totalBytes }
    }

    /// 启动/重扫：manifest 在盘 = 已安装（半截 `.part` 目录不算——占用不计、
    /// 「已下载 N 个」亦不含，与原型空态语义一致）。
    func scanInstalled() {
        var installed: Set<String> = []
        var loaded: [String: ModelManifest] = [:]
        for model in LocalModelCatalog.all {
            let dir = LocalModelCatalog.directory(repoID: model.id, root: modelsRoot)
            if let manifest = Self.readManifest(at: dir) {
                installed.insert(model.id)
                loaded[model.id] = manifest
            }
        }
        installedRepos = installed
        manifests = loaded
    }

    // MARK: - 下载 / 取消 / 删除

    /// 渠道 → 该渠道的客户端（渠道在 startDownload 入口解析一次并捕获进任务——
    /// 「下载时现选」语义：进行中任务钉死启动时渠道，中途换默认不影响在跑的）。
    private func provider(for channel: AppSettings.DownloadChannel) -> ModelFileProviding {
        channel == .modelScope ? modelScopeProvider : huggingFaceProvider
    }

    /// 启动下载（TASK-144：渠道经下载图标的弹出菜单「下载时现选」，由 UI 传入）。
    func startDownload(_ model: LocalModelInfo, channel: AppSettings.DownloadChannel) {
        guard !isDownloading(model.id) else { return }
        failureMessages[model.id] = nil
        downloadFractions[model.id] = 0
        downloadChannels[model.id] = channel

        let repoID = model.id
        let directory = LocalModelCatalog.directory(repoID: repoID, root: modelsRoot)
        let provider = provider(for: channel)
        let session = session

        tasks[repoID] = Task { [weak self] in
            do {
                try await Self.download(
                    repoID: repoID,
                    to: directory,
                    provider: provider,
                    session: session
                ) { fraction in
                    await MainActor.run { [weak self] in
                        self?.downloadFractions[repoID] = fraction
                    }
                }
                await MainActor.run { self?.downloadFinished(repoID: repoID) }
            } catch is CancellationError {
                // 用户取消：保留 .part 断点，无失败提示
                await MainActor.run { self?.downloadCancelled(repoID: repoID) }
            } catch {
                AppLog.pipeline.error("model download failed (\(repoID, privacy: .public)): \(String(describing: error), privacy: .public))")
                let message = Self.friendlyMessage(error)
                await MainActor.run { self?.downloadFailed(repoID: repoID, message: message) }
            }
        }
    }

    func cancelDownload(_ repoID: String) {
        tasks[repoID]?.cancel()
    }

    /// 删除已下载模型（整目录；调用方负责禁止删除「使用中」——与原型一致）。
    func deleteInstalled(_ repoID: String) throws {
        guard isInstalled(repoID), !isDownloading(repoID) else { return }
        let dir = LocalModelCatalog.directory(repoID: repoID, root: modelsRoot)
        try FileManager.default.removeItem(at: dir)
        installedRepos.remove(repoID)
        manifests[repoID] = nil
    }

    // MARK: - 收口

    private func downloadFinished(repoID: String) {
        let dir = LocalModelCatalog.directory(repoID: repoID, root: modelsRoot)
        if let manifest = Self.readManifest(at: dir) {
            manifests[repoID] = manifest
            installedRepos.insert(repoID)
        }
        downloadFractions[repoID] = nil
        downloadChannels[repoID] = nil
        tasks[repoID] = nil
    }

    private func downloadCancelled(repoID: String) {
        downloadFractions[repoID] = nil
        downloadChannels[repoID] = nil
        tasks[repoID] = nil
    }

    private func downloadFailed(repoID: String, message: String) {
        failureMessages[repoID] = message
        downloadFractions[repoID] = nil
        tasks[repoID] = nil
    }

    static func readManifest(at directory: URL) -> ModelManifest? {
        let url = directory.appendingPathComponent(LocalModelCatalog.manifestFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ModelManifest.self, from: data)
    }

    /// 网络类错误归并为一条用户文案（其余取 error 描述截断）。
    static func friendlyMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? "已取消" : "网络不可用，请稍后重试"
        }
        if case ModelDownloadError.checksumMismatch = error { return "文件校验失败，请重试" }
        if case ModelDownloadError.networkExhausted = error { return "网络不稳定，请稍后重试" }
        return String(String(describing: error).prefix(80))
    }

    // MARK: - 下载核心（nonisolated：文件 IO 与字节流在协作线程池跑）

    /// 下载一个仓库的全部文件到 directory。进度回调（0…1）已限频
    /// （≥progressMinInterval 或完成；测试可注 0 关闭节流）。
    /// 取消：抛 CancellationError，`.part` 保留供续传。
    nonisolated static func download(
        repoID: String,
        to directory: URL,
        provider: ModelFileProviding,
        session: URLSession,
        progressMinInterval: TimeInterval = 0.2,
        progress: @escaping (Double) async -> Void
    ) async throws {
        let fm = FileManager.default

        // 1. 文件树（含 Size/Sha256）
        let files = try await provider.fetchFiles(repoID: repoID)
        guard !files.isEmpty else { throw ModelDownloadError.networkExhausted(underlying: "empty file list") }
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        var completedBytes: Int64 = 0
        var lastReported = Date.distantPast
        func report(force: Bool = false) async {
            let now = Date()
            guard force || progressMinInterval <= 0
                || now.timeIntervalSince(lastReported) > progressMinInterval else { return }
            lastReported = now
            let fraction = totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
            await progress(fraction)
        }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // 2. 逐文件下载
        var manifestFiles: [ModelManifest.FileEntry] = []
        for file in files {
            try Task.checkCancellation()

            let dest = Self.destinationURL(for: file.path, in: directory)
            let partURL = dest.appendingPathExtension("part")
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            // 幂等：完整文件已存在（上次装完/重扫）→ 跳过
            let existingSize = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
            if let size = existingSize, size == file.size {
                completedBytes += file.size
                manifestFiles.append(.init(path: file.path, size: file.size, sha256: file.sha256))
                await report()
                continue
            }

            // 断点续传：有效 .part 前缀先计入（否则续传进度从 0% 重新起步）；
            // 越界 .part 由 downloadFile 作废重下，这里不计
            if let attrs = try? fm.attributesOfItem(atPath: partURL.path),
               let size = attrs[.size] as? Int64, size > 0, size < file.size {
                completedBytes += size
            }
            await report()
            try await Self.downloadFile(
                repoID: repoID, file: file, to: dest, partURL: partURL,
                provider: provider, session: session,
                onChunk: { delta in
                    completedBytes += delta
                    await report() // chunk 级上报（bug01）：模型字节集中在单个
                                   // safetensors，仅文件级收口会让进度冻结数分钟
                })
            await report(force: true)
            manifestFiles.append(.init(path: file.path, size: file.size, sha256: file.sha256))
        }

        // 3. manifest 原子收口（存在即「已安装」）
        let manifest = ModelManifest(
            repoID: repoID, downloadedAt: Date(), files: manifestFiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent(LocalModelCatalog.manifestFileName), options: .atomic)
        await progress(1)
    }

    /// "tokenizer/config.json" → directory/tokenizer/config.json（含中间目录创建）。
    nonisolated static func destinationURL(for path: String, in directory: URL) -> URL {
        var url = directory
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// 单文件下载：`.part` 断点续传 + Range + SHA256 边下边算（续传前先补算
    /// 已存在前缀的哈希）。网络错误重试至多 3 次（每次从当前 .part 尾部续传）；
    /// SHA 不符删 `.part` 从头一次，再不符抛 checksumMismatch。
    /// 注：每 1MB flush 经 onChunk 报告新增字节数，由调用方累计并限频上报
    /// （这里不做时间节流）。
    nonisolated private static func downloadFile(
        repoID: String,
        file: ModelRepoFile,
        to dest: URL,
        partURL: URL,
        provider: ModelFileProviding,
        session: URLSession,
        onChunk: @escaping (Int64) async -> Void
    ) async throws {
        let fm = FileManager.default
        var attempt = 0
        var checksumRetried = false

        while true {
            do {
                try Task.checkCancellation()
                var offset: Int64 = 0
                if let attrs = try? fm.attributesOfItem(atPath: partURL.path),
                   let size = attrs[.size] as? Int64, size > 0, size <= file.size {
                    offset = size
                } else {
                    try? fm.removeItem(at: partURL) // 缺失/损坏/越界（文件树更新过）的 .part 作废
                }

                var request = URLRequest(url: provider.resolveURL(repoID: repoID, path: file.path))
                if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                // 服务器不认 Range（返回 200 全量）→ 清空 .part 从头写
                if offset > 0 && http.statusCode == 200 {
                    try? fm.removeItem(at: partURL)
                    offset = 0
                }
                guard http.statusCode == 200 || http.statusCode == 206 else {
                    throw URLError(.badServerResponse)
                }

                // 打开（或创建）.part：offset==0 全新写；>0 追加
                if !fm.fileExists(atPath: partURL.path) {
                    fm.createFile(atPath: partURL.path, contents: nil)
                }
                guard let handle = FileHandle(forWritingAtPath: partURL.path) else {
                    throw URLError(.cannotWriteToFile)
                }
                defer { try? handle.close() }
                if offset > 0 { try handle.seekToEnd() }

                // 哈希：续传时先补算已存在前缀（一次性顺序读）
                var hasher = SHA256()
                if offset > 0 {
                    guard let prefix = FileHandle(forReadingAtPath: partURL.path) else {
                        throw URLError(.cannotOpenFile)
                    }
                    defer { try? prefix.close() }
                    while let chunk = try prefix.read(upToCount: 4 << 20), !chunk.isEmpty {
                        hasher.update(data: chunk)
                    }
                }

                var buffer = Data()
                buffer.reserveCapacity(1 << 20)
                var written = offset
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 1 << 20 {
                        try Task.checkCancellation()
                        buffer.withUnsafeBytes { hasher.update(bufferPointer: $0) }
                        try handle.write(contentsOf: buffer)
                        written += Int64(buffer.count)
                        await onChunk(Int64(buffer.count))
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    buffer.withUnsafeBytes { hasher.update(bufferPointer: $0) }
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    await onChunk(Int64(buffer.count))
                }
                try handle.close()

                guard written == file.size else {
                    // 字节流提前断（连接中断）：保留 .part，走网络重试
                    throw URLError(.networkConnectionLost)
                }

                // SHA256 校验（文件树未提供则跳过）
                if let expected = file.sha256 {
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    if digest != expected.lowercased() {
                        try? fm.removeItem(at: partURL)
                        if !checksumRetried {
                            checksumRetried = true
                            continue // 从头重下一次
                        }
                        throw ModelDownloadError.checksumMismatch(path: file.path)
                    }
                }

                // 原子入位
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: partURL, to: dest)
                return
            } catch let error as ModelDownloadError {
                // 校验失败是确定性错误（两次都错）：不进网络重试，立即上抛
                throw error
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= 3 {
                    throw ModelDownloadError.networkExhausted(
                        underlying: String(describing: error))
                }
                // 网络抖动：稍候即从 .part 当前尾部续传
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }
}
