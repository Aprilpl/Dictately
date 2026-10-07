import CoreAudio
import Foundation

/// 「录音时静音」（TASK-074 / FR-015）：按下快捷键开录时静音系统声音、录音结束恢复。
///
/// 实现取径（用户裁决 2026-10-01）：**公开 CoreAudio API 对系统默认输出设备做
/// 快照式静音/恢复**（kAudioDevicePropertyMute），不采用私有 MediaRemote 框架的
/// 媒体暂停——私有符号随系统版本漂移，开源分发场景不可承诺；且用户命名「静音」。
/// 语义：静音的是输出设备（播放不中断、只是无声），录音结束恢复原状。
protocol SystemAudioMuting: AnyObject {
    /// 开录时调用：默认输出设备未静音 → 记快照并静音；已静音/查询失败 → 不掺和。
    func mute()
    /// 收录时调用（所有结束路径）：仅恢复本类型亲手静音的设备，其余不碰。
    func restore()
}

/// 输出设备读写接缝（测试注入 spy；真实实现走 CoreAudio 公开 API）。
protocol SystemAudioOutputIO: AnyObject {
    /// 当前默认输出设备 ID（nil = 查询失败，按不可静音处理）。
    func defaultOutputDeviceID() -> UInt32?
    /// 设备静音态（nil = 属性不可读）。
    func isDeviceMuted(_ deviceID: UInt32) -> Bool?
    /// 设置静音态；返回是否至少写到一个声道。
    @discardableResult
    func setDeviceMuted(_ muted: Bool, deviceID: UInt32) -> Bool
}

/// CoreAudio 真实实现：默认输出设备 + kAudioDevicePropertyMute（output scope）。
/// 主声道（element 0）优先，回退声道 1/2（部分设备无主声道级静音属性）；
/// 读取取第一个可读声道，写入对全部可写声道生效（读主写分声道的不对称可容忍）。
final class CoreAudioOutputIO: SystemAudioOutputIO {
    /// 静音属性尝试的声道序：主声道（0）→ 左（1）→ 右（2）。
    private static let muteElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain, 1, 2,
    ]

    func defaultOutputDeviceID() -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    func isDeviceMuted(_ deviceID: UInt32) -> Bool? {
        for element in Self.muteElements {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
            else { continue }
            return value != 0
        }
        return nil
    }

    func setDeviceMuted(_ muted: Bool, deviceID: UInt32) -> Bool {
        var wroteAny = false
        for element in Self.muteElements {
            var value: UInt32 = muted ? 1 : 0
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            if AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
            {
                wroteAny = true
            }
        }
        return wroteAny
    }
}

/// 静音控制器：快照 = 「本类型亲手静音的设备 ID」。恢复只对该设备解除静音——
/// 用户本已静音的设备不记快照（恢复时不误开声）；录音中途换默认设备也不误伤
/// 新设备（快照锚定开录时刻的旧设备）。
/// 线程安全：开录/收口都在主线程（beginDictation / handleRecordingFinished），
/// 锁仅为防御未来调用方变化。已知边界：App 在录音中途崩溃则设备滞留静音态，
/// 由用户手动解除（不做启动时自动解除——无法区分是本 App 残留还是用户本意）。
final class SystemAudioMuter: SystemAudioMuting {
    private let io: SystemAudioOutputIO
    private let lock = NSLock()
    private var mutedDeviceID: UInt32?

    init(io: SystemAudioOutputIO = CoreAudioOutputIO()) {
        self.io = io
    }

    func mute() {
        lock.lock()
        defer { lock.unlock() }
        guard mutedDeviceID == nil else { return } // 已有快照（重复 mute）不二次覆盖
        guard let deviceID = io.defaultOutputDeviceID() else {
            AppLog.audio.notice("mute-during-recording: no default output device — skipped")
            return
        }
        guard let muted = io.isDeviceMuted(deviceID) else {
            AppLog.audio.notice("mute-during-recording: mute state unreadable — skipped")
            return
        }
        guard !muted else { return } // 用户已手动静音：不掺和，恢复时也不误开声
        guard io.setDeviceMuted(true, deviceID: deviceID) else {
            AppLog.audio.notice("mute-during-recording: device refuses mute — skipped")
            return
        }
        mutedDeviceID = deviceID
        AppLog.audio.notice("mute-during-recording: muted output device \(deviceID, privacy: .public)")
    }

    func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard let deviceID = mutedDeviceID else { return } // 未亲手静音则不碰任何设备
        mutedDeviceID = nil
        if !io.setDeviceMuted(false, deviceID: deviceID) {
            AppLog.audio.notice("mute-during-recording: unmute failed on device \(deviceID, privacy: .public)")
        }
    }
}
