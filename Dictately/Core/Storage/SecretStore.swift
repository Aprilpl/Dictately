import Foundation

/// Key 存取抽象（TASK-048，裁决见 AGENTS.md）。
/// 生产实现 = `KeychainStore`（发布版唯一允许的后端）；Debug 旁路 = `FileSecretStore`
/// （`#if DEBUG` 编译门控 + 组装点 `DICTATELY_DEV_SECRETS=1` 运行时开关，供裸跑二进制开发）。
protocol SecretStore: AnyObject {
    func set(_ value: String, for account: String) throws
    func get(_ account: String) throws -> String?
    func delete(_ account: String) throws
}

/// PRD §3 定义的 Key 账户名（`KeychainStore.Account` 为兼容别名，存量调用点不变）。
/// 听写模型页多供应商（2026-10-01 用户裁决对齐 v2-glass；2026-10-04 增 Mistral）：
/// qwen/openai/groq/mistral/custom 各存各 Key。
/// AI 服务页两级化（2026-10-02）：七家 LLM 供应商各存各 Key（DeepSeek 复用存量全局账户）。
enum SecretAccount {
    static let asrAPIKey = "asr.apiKey" // 阿里云 Qwen
    static let asrAPIKeyOpenAI = "asr.apiKey.openai"
    static let asrAPIKeyGroq = "asr.apiKey.groq"
    static let asrAPIKeyMistral = "asr.apiKey.mistral"
    static let asrAPIKeyCustom = "asr.apiKey.custom"
    static let llmAPIKey = "llm.apiKey"
    static let llmAPIKeyOpenAI = "llm.apiKey.openai"
    static let llmAPIKeyZhipu = "llm.apiKey.zhipu"
    static let llmAPIKeyBailian = "llm.apiKey.bailian"
    static let llmAPIKeyOpenRouter = "llm.apiKey.openrouter"
    static let llmAPIKeyOpenCode = "llm.apiKey.opencode"
    static let llmAPIKeyCustom = "llm.apiKey.custom"

    /// 服务商 → Key 账户名。
    static func asrAccount(for provider: AppSettings.ASRProvider) -> String {
        switch provider {
        case .qwen: return asrAPIKey
        case .openai: return asrAPIKeyOpenAI
        case .groq: return asrAPIKeyGroq
        case .mistral: return asrAPIKeyMistral
        case .custom: return asrAPIKeyCustom
        }
    }

    /// AI 服务供应商 → Key 账户名。DeepSeek 复用存量全局账户 `llm.apiKey`——
    /// 两级化之前的唯一 LLM Key 即 DeepSeek 端点所用（旧全局默认），零迁移直用。
    static func llmAccount(for provider: AppSettings.LLMProvider) -> String {
        switch provider {
        case .deepseek: return llmAPIKey
        case .openai: return llmAPIKeyOpenAI
        case .zhipu: return llmAPIKeyZhipu
        case .bailian: return llmAPIKeyBailian
        case .openrouter: return llmAPIKeyOpenRouter
        case .opencode: return llmAPIKeyOpenCode
        case .custom: return llmAPIKeyCustom
        }
    }
}

/// 读穿透缓存的 `SecretStore` 装饰器（TASK-048 层 B）。
/// 约束（AGENTS.md 硬约束 #1）：Key 读取节奏 = 每账户每进程至多一次底层读取——
/// Keychain ACL 授权弹框频率随底层读取次数放大，缓存命中不再触达底层。
/// 写/删走穿透并同步缓存（设置页保存后全链路立即可见新值）。
/// 「已知不存在」（值为 nil）同样入缓存：缺 Key 时也不会反复打底层。
final class CachingSecretStore: SecretStore {
    private let underlying: SecretStore
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    init(underlying: SecretStore) {
        self.underlying = underlying
    }

    func set(_ value: String, for account: String) throws {
        try underlying.set(value, for: account)
        lock.lock()
        defer { lock.unlock() }
        cache[account] = value
    }

    func get(_ account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[account] { return cached }
        let value = try underlying.get(account)
        cache[account] = value
        return value
    }

    func delete(_ account: String) throws {
        try underlying.delete(account)
        lock.lock()
        defer { lock.unlock() }
        cache[account] = .some(nil)
    }

    /// 启动预热（硬约束 #1「启动读一次」的落地）：后台一次性读全部账户入缓存，
    /// 避免设置页 onAppear / 首次听写现场触发底层 Keychain 读（开发期 ACL 弹框会卡主线程）。
    /// 读失败的账户不缓存（保留懒加载路径重试——「拒绝授权」≠「不存在」）。
    func prefetch(_ accounts: [String]) {
        for account in accounts {
            lock.lock()
            let isCached = cache[account] != nil
            lock.unlock()
            guard !isCached else { continue }
            do {
                let value = try underlying.get(account)
                lock.lock()
                cache[account] = value // nil（不存在）同样入缓存
                lock.unlock()
            } catch {
                continue
            }
        }
    }
}
