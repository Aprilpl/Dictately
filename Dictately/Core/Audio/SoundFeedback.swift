import AppKit

/// 效果音库（TASK-075 / 用户裁决 2026-10-01）：随 App 分发的四枚自备 mp3，
/// 位于 `Resources/Sounds/`（`.process("Resources")` 资源通道，TestAudio.mp3 同款先例）。
/// rawValue = 资源文件名（message 为小写开头，原样保留）——UserDefaults 直接存这个串。
enum EffectSound: String, CaseIterable {
    case bell = "Bell"
    case blip = "Blip"
    case ding = "Ding"
    case message = "message"

    /// 显示名（设置页 Menu 选项文案；当前即文件名，透明可对号）。
    var displayName: String { rawValue }

    /// 默认效果音（用户裁决：Blip）。
    static let defaultSound: EffectSound = .blip

    /// 存储串解析：非法/未存回退默认（沿 recordingHotkeyCombo 的非法回退模式）。
    static func from(storageName: String) -> EffectSound {
        EffectSound(rawValue: storageName) ?? .defaultSound
    }

    /// 资源定位：先查 AppResources.bundle 根（SPM process 对子目录可能打平），再查 Sounds/
    /// 子目录（保留结构时命中）——双路径兜底，单测钉死实际行为（EffectSoundTests）。
    func url(in bundle: Bundle = AppResources.bundle) -> URL? {
        bundle.url(forResource: rawValue, withExtension: "mp3")
            ?? bundle.url(forResource: rawValue, withExtension: "mp3", subdirectory: "Sounds")
    }
}

/// 打包效果音播放接缝（测试注入脚本桩）。completion 在主线程回调，Bool = 是否完整播完
/// （启动失败/资源缺失同样回调 false——**绝不悬挂调用方**，预滚链路据此照常开录）。
/// cueFraction：到文件时长的该比例处提前收口（开录提示「准备中」减半用；nil = 播完整段）。
protocol EffectSoundPlaying: AnyObject {
    func play(
        _ sound: EffectSound, volume: Float, cueFraction: Double?,
        completion: @escaping (_ playedFully: Bool) -> Void)
}

extension EffectSoundPlaying {
    /// 完整播放便捷入口（停录提示/设置页试听用）。
    func play(_ sound: EffectSound, volume: Float, completion: @escaping (Bool) -> Void) {
        play(sound, volume: volume, cueFraction: nil, completion: completion)
    }
}

/// NSSound 真实实现（主线程调用约定与 NSSound 一致）：播放完成由
/// `NSSoundDelegate.sound(_:didFinishPlaying:)` 驱动——替代定长延时（TASK-075 裁决：
/// 时长随文件自适应、播放失败即时回调、将来换音效零改码）。每次 play 新建 NSSound
/// 实例互不干扰；播放期间经 Playback 壳强持有实例与 delegate（NSSound.delegate 不保留
/// 实参，壳被释放则回调落空甚至悬垂），播完自动出队。
final class BundleEffectSoundPlayer: EffectSoundPlaying {
    /// 一次播放的持有壳：sound 与 delegate 适配器同生命周期。
    private final class Playback: NSObject, NSSoundDelegate {
        let sound: NSSound
        var onFinish: ((Bool) -> Void)?

        init?(sound: EffectSound, volume: Float) {
            guard let url = sound.url() else {
                AppLog.audio.notice("effect sound resource missing: \(sound.rawValue, privacy: .public)")
                return nil
            }
            guard let nsSound = NSSound(contentsOf: url, byReference: true) else {
                AppLog.audio.notice("effect sound unreadable: \(sound.rawValue, privacy: .public)")
                return nil
            }
            self.sound = nsSound
            super.init()
            nsSound.volume = volume
            nsSound.delegate = self
        }

        func start() -> Bool { sound.play() }

        func sound(_ sound: NSSound, didFinishPlaying successfully: Bool) {
            onFinish?(successfully)
            onFinish = nil // delegate 理论上只回调一次，双保险防重
        }
    }

    /// 在播列表：仅为保命持有（防 delegate 悬垂），播放结束自动移除。
    private var playing: [Playback] = []

    func play(
        _ sound: EffectSound, volume: Float, cueFraction: Double?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let playback = Playback(sound: sound, volume: volume) else {
            completion(false) // 资源缺失/不可读：不悬挂
            return
        }
        playing.append(playback)
        playback.onFinish = { [weak self, weak playback] ok in
            guard let self, let playback else { return }
            self.playing.removeAll { $0 === playback }
            completion(ok)
        }
        if !playback.start() {
            // play() 同步失败（无输出设备等）：delegate 不会回调，手动收口。
            playing.removeAll { $0 === playback }
            playback.onFinish = nil
            completion(false)
        }

        // 半程截断（「准备中」减半，用户裁决）：到 duration × cueFraction 处先行回调
        // （视作提示完成）再停声；届时已自然播完则空操作（不在播列表中）。
        if let cueFraction, playback.sound.duration > 0 {
            let stopAt = max(0, playback.sound.duration * cueFraction)
            DispatchQueue.main.asyncAfter(deadline: .now() + stopAt) { [weak self, weak playback] in
                guard let self, let playback else { return }
                guard self.playing.contains(where: { $0 === playback }) else { return }
                self.playing.removeAll { $0 === playback }
                playback.onFinish?(true) // 有意截断 ≠ 播放失败
                playback.onFinish = nil
                playback.sound.stop()    // stop 触发的 delegate 回调已置空，不双触发
            }
        }
    }

    /// 停止本播放器全部在播声音（设置页预览控件用；与管道的开录提示互不影响——各持实例）：
    /// 先立即回调未决 completion（UI 播放态即时复位），再停声——stop() 触发的
    /// delegate 回调已被置空，不会双触发。
    func stopAll() {
        for playback in playing {
            playback.onFinish?(false)
            playback.onFinish = nil
            playback.sound.stop()
        }
        playing.removeAll()
    }
}

/// 声音反馈（TASK-041 起；TASK-075 改自备效果音 + 「先播音后开录」预滚语义）：
/// 开录前播所选效果音、**播至半程即开录**（cueFraction 0.5——「准备中」时长减半，
/// 用户追裁；停声先于 engine 启动，无尾音灌麦）；停录播同款完整段（用户裁决）。
/// 转写完成**不发声**——成功即静默是品牌铁律（PRD/SPEC §0）。
/// 开关（settings.soundEffects）与所选效果音均每次现读，切换即时生效。
final class SoundFeedback {
    /// 音量：TASK-041 的 0.25 是系统音时代的低位控制，用户实测听不见；自备 mp3 走正常音量。
    static let volume: Float = 0.8

    /// 开录提示截断比例（用户追裁 2026-10-01：「准备中」时长减半）。
    static let startCueFraction: Double = 0.5

    private let player: EffectSoundPlaying
    /// 开关现读（settings.soundEffects）。
    private let isEnabled: () -> Bool
    /// 所选效果音现读（settings.soundEffect）。
    private let effectProvider: () -> EffectSound

    init(
        player: EffectSoundPlaying = BundleEffectSoundPlayer(),
        isEnabled: @escaping () -> Bool,
        effectProvider: @escaping () -> EffectSound = { .defaultSound }
    ) {
        self.player = player
        self.isEnabled = isEnabled
        self.effectProvider = effectProvider
    }

    /// 开录前提示（预滚入口）：开关关 → 立即 completion(true)（零延迟直开）；
    /// 开 → 播所选效果音、到半程收口，失败均回调（false = 未正常播完，调用方照样开录不挡链路）。
    func playStartCue(completion: @escaping (Bool) -> Void) {
        guard isEnabled() else {
            completion(true)
            return
        }
        player.play(
            effectProvider(), volume: Self.volume, cueFraction: Self.startCueFraction,
            completion: completion)
    }

    /// 停录提示（userStop / reachedMaxSeconds；取消与设备中断不响——用户已知情）。
    func recordingStopped() {
        guard isEnabled() else { return }
        player.play(effectProvider(), volume: Self.volume) { _ in }
    }
}
