import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

/// 权限三态（麦克风/辅助功能通用；PRD FR-014）。
enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
}

/// 麦克风授权请求接缝（DictationPipeline 注入，沿 audioMuter 先例，TASK-106）：
/// 开录前发现「未决定」态由管道主动发起系统询问——否则 AVAudioEngineRecorder.record
/// 的 authorized 前置闸门直接拒绝启动且系统弹窗永不出现（新装机/权限重置后
/// 「无法开始录音」死锁根因）。真实实现读 AVAudioApplication；测试桩零弹窗替换。
protocol MicrophonePermissionRequesting {
    /// 是否处于「未决定」态（granted/denied 皆 false，无需询问）。
    var needsRequest: Bool { get }
    /// 是否已被系统拒绝（TASK-107：failStart 判定 HUD「去授权」按钮的依据）。
    var isDenied: Bool { get }
    /// 发起系统授权询问（触发系统弹窗），返回是否授予。
    func request() async -> Bool
}

/// 真实实现：AVAudioApplication（macOS 14+，与 PermissionChecker 读状态同源）。
struct SystemMicrophonePermissionRequester: MicrophonePermissionRequesting {
    var needsRequest: Bool { AVAudioApplication.shared.recordPermission == .undetermined }
    var isDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }
    func request() async -> Bool { await AVAudioApplication.requestRecordPermission() }
}

/// 麦克风「重新授权」按钮动作分流（TASK-107 纯函数，单测覆盖，FR-019）：
/// 未决定 → App 内发起系统询问（弹窗必现）；已拒绝 → 系统不再弹窗，深链设置面板；
/// 已授权 → 无动作（绿色 chip 即反馈）。
enum MicrophoneReauthAction: Equatable {
    case requestInApp
    case openSystemSettings
    case none
}

/// 权限检测（PRD §2 Stack Integration Guide #4、FR-014）：
/// - 麦克风：AVAudioApplication.recordPermission（macOS 14+；AVCaptureDevice.authorizationStatus 为旧 API）
/// - 辅助功能：AXIsProcessTrusted（权威状态，含事件合成）+ CGPreflightListenEventAccess（listen-only 事件流预检，只读不弹窗）
/// - 深链：辅助功能系统设置面板（FR-014 原文 URL）
///
/// 真实权限状态属系统（不 mock）：查询函数只读不弹窗，单测覆盖纯映射与深链常量，
/// 并做真实状态读取冒烟；`requestMicrophoneAccess` 会触发系统弹窗，测试禁止调用。
@Observable
final class PermissionChecker {
    /// 辅助功能系统设置深链（PRD FR-014 逐字）。
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// 麦克风系统设置深链（TASK-107，FR-019；与辅助功能深链同族）。
    static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// 麦克风权限状态（UI 订阅）。
    private(set) var microphone: PermissionState = .notDetermined
    /// 辅助功能权限状态（UI 订阅）。
    private(set) var accessibility: PermissionState = .denied
    /// listen-only 事件流（CGEventTap 热键）预检结果；与 accessibility 分开供 HotkeyEngine 判断。
    private(set) var listenEventAccess: Bool = false

    init() {
        refresh()
    }

    /// 重查系统状态并发布。所有查询 API 均只读不弹窗，可在任意时刻安全调用
    /// （授权变更后的刷新策略由 onboarding/设置页驱动，Phase 1 接线）。
    func refresh() {
        microphone = Self.microphoneState(from: AVAudioApplication.shared.recordPermission)
        accessibility = Self.accessibilityState(isTrusted: AXIsProcessTrusted())
        listenEventAccess = CGPreflightListenEventAccess()
    }

    /// 请求麦克风权限（触发系统弹窗）——仅在用户主动操作（引导/设置页按钮）时调用；测试勿调。
    func requestMicrophoneAccess() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        AppLog.pipeline.notice(
            "microphone permission request granted=\(granted, privacy: .public)")
        refresh()
        // 回调值是权威答案，置于 refresh() 之后覆写（TASK-121）：授权翻转的进程内
        // 读取可能滞后（辅助功能 AXIsProcessTrusted 同族怪癖，见 OnboardingView 注释），
        // 不覆写则引导步可能因滞后读取停在「未授权」直到重启。
        microphone = granted ? .granted : .denied
    }

    /// 打开系统设置的辅助功能面板（深链）。
    func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
    }

    /// 打开系统设置的麦克风面板（深链，TASK-107）。
    func openMicrophoneSettings() {
        NSWorkspace.shared.open(Self.microphoneSettingsURL)
    }

    // MARK: - 纯映射（单测覆盖）

    /// 麦克风「重新授权」动作分流（TASK-107，FR-019）。
    static func microphoneReauthAction(for state: PermissionState) -> MicrophoneReauthAction {
        switch state {
        case .granted: return .none
        case .notDetermined: return .requestInApp
        case .denied: return .openSystemSettings
        }
    }

    /// AVAudioApplication.recordPermission（注意：该嵌套枚举的 Swift 名为小写 r，
    /// 见 SDK 头文件 NS_SWIFT_NAME(AVAudioApplication.recordPermission)）→ PermissionState。
    static func microphoneState(from permission: AVAudioApplication.recordPermission) -> PermissionState {
        switch permission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// AXIsProcessTrusted() 布尔 → PermissionState（辅助功能无「未决定」态：未授权即 denied）。
    static func accessibilityState(isTrusted: Bool) -> PermissionState {
        isTrusted ? .granted : .denied
    }
}
