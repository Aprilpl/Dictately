import Foundation

/// 强类型 UserDefaults 封装：键清单与默认值见 PRD §3 Data Model（docs/prd.md）。
/// 每次 set 立即写入 defaults（无缓存批量）；底层只存原始类型（String/Bool/Int/Double/[String]/JSON Data），
/// SwiftUI 侧 `@AppStorage("键名")` 可直接读到同样的值。API Key 不在此处（Keychain，TASK-005）。
///
/// 文件布局（TASK-115 拆分，均为同模块 extension、无访问控制变化）：
/// 本文件 = 枚举 + 键表 + defaults 注入 + 一次性迁移链 + 原始读取小工具 + 行为与生命周期；
/// 主题段在 AppSettings+Hotkey / +General / +ASR / +LLM 四个同名文件。
final class AppSettings {
    /// 热键触发方式（recordingHotkey.mode：hold|toggle|doubleTap|holdOrToggle）。
    /// holdOrToggle =「按住或切换」自动识别（FR-001：down 后 200ms 内 up 视为切换翻转，
    /// 按住 ≥200ms 松开视为 hold 结束）；风格热键已改走可选三选模式（TASK-072），
    /// holdOrToggle 仅保留给录音键的手改 defaults 残留值兜底。
    enum HotkeyMode: String {
        case hold, toggle, doubleTap, holdOrToggle
    }

    /// 界面外观（appearance：system|light|dark）
    enum Appearance: String {
        case system, light, dark
    }

    /// 转写服务商（听写模型页五选一；openai/groq/mistral/custom 同走 OpenAI 兼容
    /// /audio/transcriptions）。2026-10-06 两级化：case 顺序 = 一级页卡片顺序
    /// （qwen / openai / groq / mistral / custom）。显示名/卡片描述/端点提示/模型
    /// 预设/能力矩阵见 ASRProviderCatalog.swift（来源 docs/LLMDocs）。
    enum ASRProvider: String, CaseIterable {
        case qwen, openai, groq, mistral, custom
    }

    /// AI 服务供应商（2026-10-02 用户裁决：AI 服务页两级化，一级=供应商卡列表）。
    /// case 顺序 = 一级页卡片顺序（同日用户排序裁决：DeepSeek / 百炼 / 智谱 / OpenCode /
    /// OpenRouter / OpenAI / 自定义）。显示名/卡片描述/端点提示/模型预设见
    /// LLMProviderCatalog.swift（来源 docs/LLMDocs）；默认 DeepSeek——两级化之前的
    /// 全局配置默认即 DeepSeek 端点，行为延续。
    enum LLMProvider: String, CaseIterable {
        case deepseek, bailian, zhipu, opencode, openrouter, openai, custom
    }

    /// LLM 推理思考档位（2026-10-04 收窄：开启即最低档，仅 "low"；空 = 关闭。
    /// 关闭/开启经 ThinkingPolicy 按供应商分派出真正生效的请求参数）。
    enum LLMReasoningEffort: String {
        case low
    }

    /// 键名集中定义，避免字符串散落（与 PRD §3 键清单一一对应）。
    /// internal（原 private）：拆分后 +Hotkey/+General/+ASR/+LLM 四个 extension
    /// 文件共用——单 executable target 内 internal 等效模块私有，不外泄。
    enum Key {
        static let hotkeyMode = "recordingHotkey.mode"
        static let hotkeyEnabled = "recordingHotkey.enabled"
        static let hotkeyCombo = "recordingHotkey.combo"
        static let styleHotkeyMode = "styleHotkey.mode"
        static let appearance = "appearance"
        static let microphoneDeviceUID = "microphoneDeviceUID"
        static let microphoneFallbackNotice = "microphoneFallbackNotice"
        static let launchAtLogin = "launchAtLogin"
        static let showInDock = "showInDock"
        static let showStatusBarIcon = "showStatusBarIcon"
        static let sidebarLastPage = "sidebarLastPage"
        static let soundEffects = "soundEffects"
        static let soundEffect = "soundEffectName"
        static let autoCopyClipboard = "autoCopyClipboard"
        static let textInputMethod = "textInputMethod"
        static let escCancelsRecording = "escCancelsRecording"
        static let muteDuringRecording = "muteDuringRecording"
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let languageHints = "languageHints"
        static let keepDialect = "keepDialect"
        static let asrProvider = "asrProvider"
        // 以下 asr 平铺旧键 = 2026-10-06 两级化迁移源（settings.migrated.asrProviders
        // 存在才搬入 asr.<字段>.<provider> 分键），迁移后休眠不删（「只增不改」纪律）。
        static let asrModel = "asrModel"
        static let asrModelOpenAI = "asrModelOpenAI"
        static let asrModelGroq = "asrModelGroq"
        static let asrModelMistral = "asrModelMistral"
        static let asrModelCustom = "asrModelCustom"
        static let asrVocabulary = "asrVocabulary"
        static let asrBaseURL = "asrBaseURL"
        static let asrCustomBaseURL = "asrCustomBaseURL"
        static let llmModel = "llmModel"
        static let llmBaseURL = "llmBaseURL"
        static let llmTemperatureText = "llmTemperatureText"
        static let llmReasoningEffort = "llmReasoningEffort"
        static let llmProvider = "llmProvider"
        static let opencodeSessionID = "opencode.sessionID"
        static let autoRetryOnce = "autoRetryOnce"
        static let audioRetentionDays = "audioRetentionDays"
        static let onboardingCompleted = "onboardingCompleted"
    }

    /// internal（原 private）：供同名 extension 文件存取（理由同 Key）。
    let defaults: UserDefaults

    /// 注入 defaults 便于测试用 UserDefaults(suiteName:) 隔离；生产用 .standard。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateOnce()
    }

    /// 一次性迁移：温度默认「空=不携带」→ 0.3（2026-10-01 早间裁决）→ 0.5（同日晚间裁决）
    /// → 0.7（同日用户裁决：默认值即 0.7，字段直接显示数值）。
    /// 仅迁移上一轮迁移产物（"0.3"/"0.5"）与本机残留空串；用户主动设置的其他值不动。
    private func migrateOnce() {
        // 先捕获「温度旧键是否本来就存在」——温迁链会写 llmTemperatureText（"0.7"），
        // 若在其后判定会把新装误判为存量（2026-10-02 供应商分键迁移的检测依据）。
        let hadLegacyTemperature = defaults.object(forKey: Key.llmTemperatureText) != nil
        let flag03 = "settings.migrated.llmTemperatureDefault"
        if !bool(flag03, default: false) {
            if string(Key.llmTemperatureText, default: "").isEmpty {
                defaults.set("0.3", forKey: Key.llmTemperatureText)
            }
            defaults.set(true, forKey: flag03)
        }
        let flag05 = "settings.migrated.llmTemperatureDefault05"
        if !bool(flag05, default: false) {
            if string(Key.llmTemperatureText, default: "") == "0.3" {
                defaults.set("0.5", forKey: Key.llmTemperatureText)
            }
            defaults.set(true, forKey: flag05)
        }
        let flag07 = "settings.migrated.llmTemperatureDefault07"
        if !bool(flag07, default: false) {
            let current = string(Key.llmTemperatureText, default: "")
            if current == "0.5" || current.isEmpty {
                defaults.set("0.7", forKey: Key.llmTemperatureText)
            }
            defaults.set(true, forKey: flag07)
        }
        // 2026-10-02 AI 服务两级页：全局单键 → 按供应商分键（llm.baseURL.<provider> 等）。
        // 在温迁链之后执行：搬运的是温迁终值（"0.3"→"0.7" 链跑完再搬）。存量判定 =
        // URL/模型/推理任一旧键存在（只有旧「保存」会写），或温度键在本次 init 时点前
        // 就存在（hadLegacyTemperature，排除温迁链刚写入的情况）；存量把旧有效值搬入
        // DeepSeek 槽（旧全局默认即 DeepSeek 端点，行为零变化）。旧键迁移后休眠不再读取
        // （与 DB migration「只增不改」同一纪律）。
        let llmProvidersFlag = "settings.migrated.llmProviders"
        if !bool(llmProvidersFlag, default: false) {
            let legacyURL = defaults.string(forKey: Key.llmBaseURL)
            let legacyModel = defaults.string(forKey: Key.llmModel)
            let legacyEffort = defaults.string(forKey: Key.llmReasoningEffort)
            if legacyURL != nil || legacyModel != nil || legacyEffort != nil || hadLegacyTemperature {
                defaults.set(legacyURL ?? "https://api.deepseek.com/v1", forKey: "llm.baseURL.deepseek")
                defaults.set(legacyModel ?? "deepseek-chat", forKey: "llm.model.deepseek")
                defaults.set(string(Key.llmTemperatureText, default: "0.7"), forKey: "llm.temperatureText.deepseek")
                defaults.set(legacyEffort ?? "", forKey: "llm.reasoningEffort.deepseek")
            }
            defaults.set(LLMProvider.deepseek.rawValue, forKey: Key.llmProvider)
            defaults.set(true, forKey: llmProvidersFlag)
        }
        // 2026-10-03 模型下拉与自定义 ID 分离（TASK-096）：`llm.model.<provider>` 继续
        // 作为唯一「生效模型」键（LLMConfig.live / 一级卡 chip 读它，本迁移不动它）；
        // 新增 preset/usesCustom/customID 三个 UI 状态键，此处按存量值播种分类——
        // 在预设列表内 → preset 键；不在（旧「自定义…」输入的自定义 ID）→ customID 键
        // + usesCustom=true。新装无存量键 → 全部落缺省零副作用；旧键休眠不删。
        let llmModelStateFlag = "settings.migrated.llmModelState"
        if !bool(llmModelStateFlag, default: false) {
            for provider in LLMProvider.allCases {
                guard let stored = defaults.string(forKey: "llm.model.\(provider.rawValue)"),
                      !stored.isEmpty else { continue }
                if provider.modelPresets.contains(where: { $0.id == stored }) {
                    defaults.set(stored, forKey: "llm.model.preset.\(provider.rawValue)")
                } else {
                    defaults.set(stored, forKey: "llm.model.customID.\(provider.rawValue)")
                    defaults.set(true, forKey: "llm.model.usesCustom.\(provider.rawValue)")
                }
            }
            defaults.set(true, forKey: llmModelStateFlag)
        }
        // 2026-10-04 推理思考收窄（用户裁决：默认关闭且生效、开启即最低档）：
        // 「中/高」档位退役——存量非 "low" 值（medium/high/历史杂值）一律归零为关闭
        // （读取侧 live() 也只认 "low"，此处清值防 UI 回显出已退役档位）。仅触碰
        // 实际存在的非空值：新装不写键保持 nil，"low" 原样保留。置于迁移链末端——
        // llmProviders 迁移刚搬入 DeepSeek 槽的旧全局档位值也一并归零。
        let llmReasoningFlag = "settings.migrated.llmReasoningSimplify"
        if !bool(llmReasoningFlag, default: false) {
            for provider in LLMProvider.allCases {
                let key = "llm.reasoningEffort.\(provider.rawValue)"
                if let stored = defaults.string(forKey: key), !stored.isEmpty, stored != "low" {
                    defaults.set("", forKey: key)
                }
            }
            defaults.set(true, forKey: llmReasoningFlag)
        }
        // 2026-10-06 听写模型两级页（对齐 AI 服务页）：平铺旧键 → 按供应商分键
        // （asr.baseURL.<provider> / asr.model.<provider>）。旧键存在才搬（新装零写入，
        // 保持 nil 由 ASRProviderCatalog 默认值兜底）；旧值或是用户设置、或是旧默认
        // （与 catalog 默认同值，搬运幂等无害）。openai/groq/mistral 无旧 Base URL 键
        // （端点原硬编码在 ASRConfig.live），直接落 catalog 官方默认。
        let asrProvidersFlag = "settings.migrated.asrProviders"
        if !bool(asrProvidersFlag, default: false) {
            let legacyMapping: [(old: String, new: String)] = [
                (Key.asrModel, "asr.model.qwen"),
                (Key.asrModelOpenAI, "asr.model.openai"),
                (Key.asrModelGroq, "asr.model.groq"),
                (Key.asrModelMistral, "asr.model.mistral"),
                (Key.asrModelCustom, "asr.model.custom"),
                (Key.asrBaseURL, "asr.baseURL.qwen"),
                (Key.asrCustomBaseURL, "asr.baseURL.custom"),
            ]
            for mapping in legacyMapping where defaults.object(forKey: mapping.old) != nil {
                defaults.set(defaults.string(forKey: mapping.old) ?? "", forKey: mapping.new)
            }
            defaults.set(true, forKey: asrProvidersFlag)
        }
        // 2026-10-06 模型下拉与自定义 ID 分离（对齐 TASK-098）：`asr.model.<provider>`
        // 继续作唯一「生效模型」键（ASRConfig.live / 一级卡 chip 读它，本迁移不动它）；
        // preset/usesCustom/customID 三 UI 状态键按存量值播种分类——在预设列表内 →
        // preset 键；不在（旧手输模型 ID）→ customID + usesCustom=true（旧自定义用户
        // 呈现零变化）。新装无存量键 → 全部落缺省零副作用；旧键休眠不删。
        let asrModelStateFlag = "settings.migrated.asrModelState"
        if !bool(asrModelStateFlag, default: false) {
            for provider in ASRProvider.allCases {
                guard let stored = defaults.string(forKey: "asr.model.\(provider.rawValue)"),
                      !stored.isEmpty else { continue }
                if provider.modelPresets.contains(where: { $0.id == stored }) {
                    defaults.set(stored, forKey: "asr.model.preset.\(provider.rawValue)")
                } else {
                    defaults.set(stored, forKey: "asr.model.customID.\(provider.rawValue)")
                    defaults.set(true, forKey: "asr.model.usesCustom.\(provider.rawValue)")
                }
            }
            defaults.set(true, forKey: asrModelStateFlag)
        }
    }

    // MARK: - 原始类型读取小工具（未设置/类型不符时回退默认值，不崩溃）
    // internal（原 private）：供同名 extension 文件共用（理由同 Key）。

    func bool(_ key: String, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        (defaults.object(forKey: key) as? Int) ?? fallback
    }

    func double(_ key: String, default fallback: Double) -> Double {
        (defaults.object(forKey: key) as? Double) ?? fallback
    }

    func string(_ key: String, default fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    // MARK: - 行为与生命周期

    /// 网络类错误自动重试一次（FR-013，默认开）。
    var autoRetryOnce: Bool {
        get { bool(Key.autoRetryOnce, default: true) }
        set { defaults.set(newValue, forKey: Key.autoRetryOnce) }
    }

    /// 成功条目音频保留天数（FR-018，默认 30；0=永久）。
    var audioRetentionDays: Int {
        get { int(Key.audioRetentionDays, default: 30) }
        set { defaults.set(newValue, forKey: Key.audioRetentionDays) }
    }

    var onboardingCompleted: Bool {
        get { bool(Key.onboardingCompleted, default: false) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }
}
