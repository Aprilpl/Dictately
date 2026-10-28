import Foundation

/// 本地听写模型目录（TASK-134，2026-10-11 用户定稿）。
/// 数据源 = docs/ASR 两份调研（ModelScope 2026-10-11 快照）+ 原型
/// docs/design-demos/local-asr-models-final.html——组内排序、体积/内存/语种
/// 照抄原型；分节顺序 2026-10-13 用户追裁改为 Qwen3 → Whisper → BELLE
/// （不再照抄原型）；模型名/量化档/体积为仓库实测，下载量仅原型展示不入库。
/// TASK-142（2026-10-13）：实测数据面落地，质量星级/速度档/实测内存/特性
/// 全部逐字段转录自原型 local-asr-models-bench.html 的 MODELS 数组
/// （数据源 docs/local-model-bench/report.md，M1 Pro/16GB 实测 392 次转写）。
/// 全部仓库均为 mlx-community 的 MLX 转换版，运行时统一为 mlx-audio
/// （0.5.8 上游含 whisper / qwen3_asr 等家族；Fun-ASR 2512 系列虽在上游有
/// fun_asr_nano 家族，但 mlx-community 实际发布的是 mlx-audio-plus fork 的
/// 转换格式（model_type=funasr），上游 0.5.8 加载必败，三款已下架——
/// TASK-137，勘误 §57「前提已消失」的结论；SenseVoice 亦于 TASK-138 下架，
/// 目录收敛为三组）。
/// TASK-144 渠道约束：**新增模型的 repo id 必须在两渠道同名存在**（HF 原生
/// mlx-community + ModelScope .cn 镜像，下载键即 repo id，无映射表）；实测
/// ModelScope .ai 国际站无 mlx-community 组织，海外渠道不采 .ai。另：wb4 的
/// sizeBytes 沿用主权重文件口径（42MB，与 bench 文案一致）——进度总量以文件
/// 树实测为准不受此影响，勿为「对齐仓库全量 46MB」单改此值（会与已裁决的
/// 描述/特性 chip 文案打架）。
enum LocalModelGroup: String, CaseIterable, Identifiable {
    /// Qwen3-ASR 系列（阿里开源；组内体积升序）。
    case qwen3ASR
    /// Whisper 系列（OpenAI 官方；组内体积升序）。
    case whisperOfficial
    /// Whisper BELLE 系列（BELLE-2 中文微调）。
    case whisperBelle

    var id: String { rawValue }

    /// 组名（Localizable；case 顺序 = 显示顺序，allCases 驱动）。
    var nameKey: String { "models.local.group.\(rawValue)" }

    /// 组说明（本地化，原型 gnote 对应）。
    var noteKey: String { "models.local.group.\(rawValue).note" }
}

/// 卡片徽标：recommended = 品牌蓝（唯一推荐位次）；否则绿（特色能力）。
/// 文案走 Localizable（TASK-142 本地化化，沿 descKey 纪律）。
struct LocalModelBadge: Equatable {
    let textKey: String
    let recommended: Bool
}

/// 速度档（原型 .tier：fast 快=绿 / mid 中=蓝 / slow 慢、unstable 不稳=橙）。
enum LocalModelSpeedTier: String, Equatable {
    case fast, mid, slow, unstable

    var labelKey: String { "models.local.tier.\(rawValue)" }
}

/// 特性 chip（原型 .feat：isGood 绿色正面 / 否则橙色警示）。
struct LocalModelFeature: Equatable {
    let textKey: String
    let isGood: Bool
}

/// 单个本地模型条目（值类型，纯数据）。
struct LocalModelInfo: Equatable, Identifiable {
    /// ModelScope 仓库全名（"mlx-community/…"，全局唯一，作下载键）。
    let id: String
    /// 显示名（专有名词，不本地化）。
    let name: String
    /// 量化档（4bit / 8bit / fp16 / fp32）。
    let quant: String
    /// 参数量显示串（"809M"/"0.6B"；无公开数据 = nil）。
    let params: String?
    /// 仓库文件实测总体积（字节；2026-10-11 快照，卡片展示与进度总量基准）。
    let sizeBytes: Int64
    /// 实测稳态内存显示串（"≈0.8 GB"，worker 进程 RSS 基准；TASK-142 覆写旧估）。
    let memHint: String?
    /// 徽标（nil = 无；wt4 唯一无徽标款）。
    let badge: LocalModelBadge?
    /// 描述文案 key（Localizable）。
    let descKey: String
    let group: LocalModelGroup
    // MARK: TASK-142 实测数据面（bench 原型逐字段转录）
    /// 中/英质量星级（1–5，半星步进；以 qwen API 转写为参照系）。
    let qualityZH: Double
    let qualityEN: Double
    /// 速度档 + 热转写耗时（中文长音频为主基准，≈每分钟音频）。
    let speedTier: LocalModelSpeedTier
    let speedZH: String
    let speedEN: String
    /// 语言/方言 neutral chips（Localizable key；仅 Qwen3 系有）。
    let langChipKeys: [String]
    /// 特性 chips（正面绿/警示橙）。
    let features: [LocalModelFeature]
}

enum LocalModelCatalog {
    /// 全部 7 款（14→11→8→7 三轮退役，TASK-134/137/138；显示序 = group 分节
    /// Qwen3 → Whisper 官方 → Whisper BELLE（2026-10-13 用户追裁）+ 组内体积升序）。
    static let all: [LocalModelInfo] = qwen3 + whisperOfficial + whisperBelle

    /// 组内模型列表（2026-10-11 用户追裁：按体积**升序**——分组分类不变，
    /// 原「组内推荐位次」退役；同体积并列保持声明序，Swift sort 不保证稳定故显式带下标）。
    static func models(in group: LocalModelGroup) -> [LocalModelInfo] {
        all.enumerated()
            .filter { $0.element.group == group }
            .sorted {
                $0.element.sizeBytes != $1.element.sizeBytes
                    ? $0.element.sizeBytes < $1.element.sizeBytes
                    : $0.offset < $1.offset
            }
            .map(\.element)
    }

    static func model(id: String) -> LocalModelInfo? {
        all.first { $0.id == id }
    }

    // MARK: - 路径

    /// 模型落盘目录：`<modelsRoot>/<namespace>/<model>`（repo id 的 "/" 拆两层，
    /// 避免目录名里出现分隔符；modelsRoot = 数据目录/Models，见 ModelDownloadManager）。
    static func directory(repoID: String, root: URL) -> URL {
        let parts = repoID.split(separator: "/").map(String.init)
        guard parts.count == 2 else {
            return root.appendingPathComponent(repoID.replacingOccurrences(of: "/", with: "__"))
        }
        return root.appendingPathComponent(parts[0], isDirectory: true)
            .appendingPathComponent(parts[1], isDirectory: true)
    }

    /// 已安装标记文件名（内容 = 文件清单 manifest；存在即视为已安装）。
    static let manifestFileName = ".dictately-manifest.json"

    // MARK: - 体积格式化（原型口径：≥1 GB 两位小数，否则整 MB）

    /// 卡片/按钮尺寸显示（"864 MB" / "1.76 GB"）。
    static func sizeText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    /// 汇总行尺寸显示（一位小数，"≈1.9 GB"）。
    static func storageText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    // MARK: - 数据（组内顺序 = 原型定稿；体积 = 仓库实测快照）

    private static let whisperOfficial: [LocalModelInfo] = [
        LocalModelInfo(
            id: "mlx-community/whisper-large-v3-turbo-asr-4bit",
            name: "Whisper Large v3 Turbo", quant: "4bit", params: "809M",
            sizeBytes: 463_460_000, memHint: "≈0.6 GB",
            badge: nil,
            descKey: "models.local.m.turbo4.desc", group: .whisperOfficial,
            qualityZH: 3, qualityEN: 4,
            speedTier: .slow, speedZH: "8.7s", speedEN: "11.8s",
            langChipKeys: [],
            features: [
                LocalModelFeature(textKey: "models.local.feat.noPunct", isGood: false),
                LocalModelFeature(textKey: "models.local.feat.tailHalluc", isGood: false),
                LocalModelFeature(textKey: "models.local.feat.cpuLow", isGood: true),
            ]),
        LocalModelInfo(
            id: "mlx-community/whisper-large-v3-turbo-asr-8bit",
            name: "Whisper Large v3 Turbo", quant: "8bit", params: "809M",
            sizeBytes: 863_660_000, memHint: "≈1.0 GB",
            badge: LocalModelBadge(textKey: "models.local.badge.enPick", recommended: false),
            descKey: "models.local.m.turbo8.desc", group: .whisperOfficial,
            qualityZH: 3, qualityEN: 5,
            speedTier: .slow, speedZH: "8.6s", speedEN: "5.2s",
            langChipKeys: [],
            features: [
                LocalModelFeature(textKey: "models.local.feat.noPunct", isGood: false),
                LocalModelFeature(textKey: "models.local.feat.enStable", isGood: true),
                LocalModelFeature(textKey: "models.local.feat.zhHalluc", isGood: false),
            ]),
        LocalModelInfo(
            id: "mlx-community/whisper-base-asr-4bit",
            name: "Whisper Base", quant: "4bit", params: "74M",
            sizeBytes: 42_220_000, memHint: "≈0.2 GB",
            badge: LocalModelBadge(textKey: "models.local.badge.tiny", recommended: false),
            descKey: "models.local.m.base4.desc", group: .whisperOfficial,
            qualityZH: 1.5, qualityEN: 3.5,
            speedTier: .unstable, speedZH: "3.0s", speedEN: "6.9s",
            langChipKeys: [],
            features: [
                LocalModelFeature(textKey: "models.local.feat.unstableOut", isGood: false),
                LocalModelFeature(textKey: "models.local.feat.cpuFull", isGood: false),
                LocalModelFeature(textKey: "models.local.feat.tiny42", isGood: true),
            ]),
    ]

    private static let whisperBelle: [LocalModelInfo] = [
        LocalModelInfo(
            id: "mlx-community/belle-whisper-large-v3-turbo-zh-8bit",
            name: "Belle Whisper Turbo 中文版", quant: "8bit", params: "809M",
            sizeBytes: 864_000_000, memHint: "≈1.0 GB",
            badge: LocalModelBadge(textKey: "models.local.badge.zhSpecialized", recommended: false),
            descKey: "models.local.m.belleturbo.desc", group: .whisperBelle,
            qualityZH: 4, qualityEN: 1,
            speedTier: .mid, speedZH: "3.1s", speedEN: "13.3s",
            langChipKeys: [],
            features: [
                LocalModelFeature(textKey: "models.local.feat.punct", isGood: true),
                LocalModelFeature(textKey: "models.local.feat.stable", isGood: true),
                LocalModelFeature(textKey: "models.local.feat.enUnavailable", isGood: false),
            ]),
    ]

    private static let qwen3: [LocalModelInfo] = [
        LocalModelInfo(
            id: "mlx-community/Qwen3-ASR-0.6B-8bit",
            name: "Qwen3-ASR 0.6B", quant: "8bit", params: "0.6B",
            sizeBytes: 1_010_000_000, memHint: "≈1.1 GB",
            badge: LocalModelBadge(textKey: "models.local.badge.precision", recommended: false),
            descKey: "models.local.m.q068.desc", group: .qwen3ASR,
            qualityZH: 5, qualityEN: 5,
            speedTier: .fast, speedZH: "2.1s", speedEN: "3.0s",
            langChipKeys: ["models.local.lang.species", "models.local.lang.dialects"],
            features: [
                LocalModelFeature(textKey: "models.local.feat.punct", isGood: true),
                LocalModelFeature(textKey: "models.local.feat.stable", isGood: true),
                LocalModelFeature(textKey: "models.local.feat.enFidelity", isGood: true),
            ]),
        LocalModelInfo(
            id: "mlx-community/Qwen3-ASR-1.7B-4bit",
            name: "Qwen3-ASR 1.7B", quant: "4bit", params: "1.7B",
            sizeBytes: 1_610_000_000, memHint: "≈1.7 GB",
            badge: LocalModelBadge(textKey: "models.local.badge.ceiling", recommended: false),
            descKey: "models.local.m.q174.desc", group: .qwen3ASR,
            qualityZH: 5, qualityEN: 5,
            speedTier: .mid, speedZH: "3.6s", speedEN: "5.7s",
            langChipKeys: ["models.local.lang.species", "models.local.lang.dialects"],
            features: [
                LocalModelFeature(textKey: "models.local.feat.punct", isGood: true),
                LocalModelFeature(textKey: "models.local.feat.stable", isGood: true),
                LocalModelFeature(textKey: "models.local.feat.memMax", isGood: false),
            ]),
        LocalModelInfo(
            id: "mlx-community/Qwen3-ASR-0.6B-4bit",
            name: "Qwen3-ASR 0.6B", quant: "4bit", params: "0.6B",
            sizeBytes: 710_000_000, memHint: "≈0.8 GB",
            badge: LocalModelBadge(textKey: "models.local.badge.best", recommended: true),
            descKey: "models.local.m.q064.desc", group: .qwen3ASR,
            qualityZH: 5, qualityEN: 4.5,
            speedTier: .fast, speedZH: "1.9s", speedEN: "2.7s",
            langChipKeys: ["models.local.lang.species", "models.local.lang.dialects"],
            features: [
                LocalModelFeature(textKey: "models.local.feat.punct", isGood: true),
                LocalModelFeature(textKey: "models.local.feat.stable", isGood: true),
            ]),
    ]

    // FunASR 组整组退役：Fun-ASR 2512 三款 2026-10-13 下架（TASK-137，
    // mlx-community 发布的是 mlx-audio-plus fork 转换格式，钉版上游
    // mlx-audio 0.5.8 加载必败且质量对 Qwen3-ASR 无优势）；最后一员
    // SenseVoice Small 2026-10-13 下架（TASK-138，用户裁决——速度生态位
    // 仅剩风格润色链路一途，直接听写质量粗糙，产品收敛为三组）。
}
