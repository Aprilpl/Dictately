import Foundation

/// 「测试连接」探测音频（2026-09-30 起，TASK-022 验收期间用户指定）：
/// 内置 4.2 秒真实语音 MP3（源 docs/audio/test.mp3 → Resources/TestAudio.mp3，
/// 内容「你好，我是你的语音助理小贝。」，16.8KB / Base64 后 22KB）。
///
/// 取代旧 1s 静音 WAV 探测（SilentWAV）：静音只能证明「服务可达」，且该模型版本
/// 对无语音音频返回 400 `ASR_RESPONSE_HAVE_NO_WORDS`（见 ASRError.map 注释）；
/// 真实语音走完整识别链路（鉴权→上传→解码→转写→计费），返回文本与真实耗时，
/// 「测试连接」可直接显示「连接成功 · XXXms」。实测往返 ~0.6s / 110 input tokens。
enum TestProbeAudio {
    enum ProbeError: Error, CustomStringConvertible {
        /// AppResources.bundle 里找不到 TestAudio.mp3（资源未随包：检查 Resources/ 与 build.sh 拷贝）。
        case resourceMissing
        var description: String {
            switch self {
            case .resourceMissing: return "内置探测音频缺失（TestAudio.mp3）"
            }
        }
    }

    /// 内置探测音频的 bundle URL（SPM process 资源，经 AppResources.bundle 定位；
    /// 直接交给 ASREngine.transcribe(audioFileAt:) 读取，无需临时文件中转）。
    static func bundledURL() throws -> URL {
        guard let url = AppResources.bundle.url(forResource: "TestAudio", withExtension: "mp3") else {
            throw ProbeError.resourceMissing
        }
        return url
    }
}
