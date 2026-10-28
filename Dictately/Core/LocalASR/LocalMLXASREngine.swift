import Foundation

/// 本地 MLX 转写引擎（TASK-134）：实现既有 ASREngine 协议（协议注释预留位），
/// DictationPipeline 零改动——经 ActiveASREngine 按 settings.asrMode 分流接入。
///
/// 状态自检全部走磁盘（manifest / 就绪标记），不读 UI 层可变状态（线程安全，
/// transcribe 在协作线程池执行）：
/// - 运行时就绪 = LocalRuntimeManager 的标记文件在盘；
/// - 模型就绪 = 模型目录 manifest 在盘（下载器原子收口）。
final class LocalMLXASREngine: ASREngine {
    private let activeModelProvider: () -> String?
    private let runtime: LocalRuntimeManager
    private let session: LocalASRSession
    private let modelsRoot: URL
    private let clock: () -> Double
    private var idleTimer: Task<Void, Never>?

    init(
        activeModelProvider: @escaping () -> String?,
        runtime: LocalRuntimeManager,
        session: LocalASRSession,
        modelsRoot: URL,
        clock: @escaping () -> Double = { CFAbsoluteTimeGetCurrent() }
    ) {
        self.activeModelProvider = activeModelProvider
        self.runtime = runtime
        self.session = session
        self.modelsRoot = modelsRoot
        self.clock = clock

        // 空闲自动卸载（用户裁决：5 分钟无转写杀进程释放统一内存）
        let sessionRef = session
        idleTimer = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await MainActor.run { sessionRef.unloadIfIdle() }
            }
        }
    }

    deinit {
        idleTimer?.cancel()
    }

    func transcribe(audioFileAt url: URL, config: ASRConfig) async throws -> ASRTranscript {
        let started = clock()

        guard runtime.isReadyOnDisk else {
            throw ASRError.localRuntimeMissing
        }
        guard let repoID = activeModelProvider(),
              LocalModelCatalog.model(id: repoID) != nil else {
            throw ASRError.localModelMissing
        }
        let directory = LocalModelCatalog.directory(repoID: repoID, root: modelsRoot)
        guard ModelDownloadManager.readManifest(at: directory) != nil else {
            throw ASRError.localModelMissing
        }

        let result: LocalWorkerResult
        do {
            result = try await session.transcribe(modelDirectory: directory, audioURL: url)
        } catch let error as LocalWorkerError {
            AppLog.pipeline.error("local transcribe failed: \(String(describing: error), privacy: .public)")
            throw ASRError.localEngineFailed(String(String(describing: error).prefix(120)))
        }

        // 空文本与 API 语义对齐（ASRError.emptyResult——误触守卫/纯静音同文案）
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASRError.emptyResult
        }
        let latencyMs = Int(((clock() - started) * 1000).rounded())
        return ASRTranscript(
            text: result.text,
            durationSeconds: result.durationSeconds,
            requestID: nil,
            latencyMs: latencyMs)
    }
}

/// 听写引擎总路由（TASK-134）：本地模式且本地模型有效 → LocalMLXASREngine；
/// 否则走 API 路由（qwen 契约 A / OpenAI 兼容）。每次转写现读 settings
/// （沿 triggerProvider 模式——切换「使用」即时生效，无需重建引擎）。
/// 两路注入协议类型（ASREngine）——单测可双 fake 验分流。
final class ActiveASREngine: ASREngine {
    private let modeProvider: () -> AppSettings.ASRMode
    private let api: ASREngine
    private let local: ASREngine

    init(
        modeProvider: @escaping () -> AppSettings.ASRMode,
        api: ASREngine,
        local: ASREngine
    ) {
        self.modeProvider = modeProvider
        self.api = api
        self.local = local
    }

    func transcribe(audioFileAt url: URL, config: ASRConfig) async throws -> ASRTranscript {
        if modeProvider() == .local {
            return try await local.transcribe(audioFileAt: url, config: config)
        }
        return try await api.transcribe(audioFileAt: url, config: config)
    }
}
