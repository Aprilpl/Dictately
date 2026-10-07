import Foundation
import GRDB

/// AI 风格（PRD §3 styles 表，列名 snake_case 映射）。
/// Phase 0 骨架：字段全覆盖建模；CRUD/内置种子/hotkey 互斥在 Phase 2（TASK-025）补全。
struct Style: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "styles"

    var id: Int64?
    var name: String
    /// 逗号分隔标签。
    var tags: String?
    var description: String?
    /// system prompt，{text} 占位原始转写。
    var prompt: String
    /// 内置风格（意图识别 / 口语润色 / 中英互译；不可删）。
    var isBuiltin: Bool
    /// 绑定的快捷键组合存储串（HotkeyCombo.storageString，如 "cmd+18"；nil = 未绑定；
    /// 同值互斥在应用层校验。2026-10-01 裁决 #12：槽位整数 1|2 升级为任意组合）。
    var hotkeyCombo: String?
    var enabled: Bool
    var sortOrder: Int
    /// Unix 秒（含小数）。
    var createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case tags
        case description
        case prompt
        case isBuiltin = "is_builtin"
        case hotkeyCombo = "hotkey_combo"
        case enabled
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: Int64? = nil,
        name: String,
        tags: String? = nil,
        description: String? = nil,
        prompt: String,
        isBuiltin: Bool = false,
        hotkeyCombo: String? = nil,
        enabled: Bool = true,
        sortOrder: Int = 0,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.description = description
        self.prompt = prompt
        self.isBuiltin = isBuiltin
        self.hotkeyCombo = hotkeyCombo
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 插入后回填自增 id（MutablePersistableRecord）。
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 风格仓库：CRUD + 内置种子 + 快捷键组合互斥（TASK-025 补全，裁决 #12 组合化）。
final class StyleRepository {
    /// 任一写操作（insert/update/delete）后发布——AppEnvironment 订阅重算引擎绑定集
    /// （吞事件判定用）；object = 发出变更的仓库实例。
    static let didChangeNotification = Notification.Name("com.dictately.styles.didChange")

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - CRUD

    /// 插入风格，返回带自增 id 的落库实例。
    @discardableResult
    func insert(_ style: Style) throws -> Style {
        var copy = style
        try database.dbQueue.write { db in
            try copy.insert(db) // didInsert 回填 id（mutating）
        }
        postDidChange()
        return copy
    }

    /// 更新风格（编辑器保存）。快捷键组合互斥在同一事务内处理。
    @discardableResult
    func update(_ style: Style) throws -> Style {
        try database.dbQueue.write { db in
            if let combo = style.hotkeyCombo {
                // 互斥：同组合绑定唯一——其他风格的该组合清空（PRD §3 Relationships）
                try db.execute(
                    sql: "UPDATE styles SET hotkey_combo = NULL, updated_at = ? WHERE hotkey_combo = ? AND id != ?",
                    arguments: [style.updatedAt, combo, style.id ?? -1])
            }
            try style.update(db)
        }
        postDidChange()
        return style
    }

    /// 删除自定义风格（内置风格由调用方 UI 拦截；entries.style_id 经 FK SET NULL 保留历史）。
    func delete(id: Int64) throws {
        _ = try database.dbQueue.write { db in
            try Style.deleteOne(db, key: id)
        }
        postDidChange()
    }

    /// 按 id 取单条（编辑器载入）。
    func fetch(id: Int64) throws -> Style? {
        try database.dbQueue.read { db in
            try Style.fetchOne(db, key: id)
        }
    }

    /// 全量读取（按 sort_order、id 升序——列表默认展示序）。
    func fetchAll() throws -> [Style] {
        try database.dbQueue.read { db in
            try Style.order(Column("sort_order"), Column("id")).fetchAll(db)
        }
    }

    /// 按快捷键组合存储串取绑定风格（热键触发映射；未绑定/停用返回 nil）。
    func fetchByHotkey(_ combo: String) throws -> Style? {
        try database.dbQueue.read { db in
            try Style
                .filter(Column("hotkey_combo") == combo && Column("enabled") == true)
                .fetchOne(db)
        }
    }

    /// 写操作完成后的变更广播（主线程无关：在写调用线程发出，订阅方自行调度）。
    private func postDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - 内置种子（FR-009）

    /// 首启幂等种子：意图识别（⌘1、排序 1 在上）、口语润色（⌘2、排序 2）、
    /// 中英互译（⌘3、排序 3，2026-10-02 第三内置风格）。
    /// 排序 2026-10-01 用户裁决：意图识别在上（列表按 sort_order, id 升序）。
    /// 口语润色为 2026-10-01 改名（原「口语化整理」）。Prompt 逐字取 FR-009。
    /// 仅在 styles 表为空时写入——用户后续编辑不受二次种子影响（幂等语义：只跑一次）；
    /// 存量装机由 insertMissingBuiltinTranslate 补种第三条。
    @discardableResult
    func seedBuiltinsIfEmpty(now: Double = Date().timeIntervalSince1970) throws -> Bool {
        try database.dbQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM styles") ?? 0
            guard count == 0 else { return false }

            var casual = Style(
                name: "口语润色",
                tags: "写作",
                description: BuiltinStyleDescriptions.casual,
                prompt: BuiltinStylePrompts.casual,
                isBuiltin: true,
                hotkeyCombo: HotkeyCombo.builtinCasual.storageString,
                enabled: true,
                sortOrder: 2,
                createdAt: now,
                updatedAt: now
            )
            try casual.insert(db)

            var intent = Style(
                name: "意图识别",
                tags: "分析",
                description: BuiltinStyleDescriptions.intent,
                prompt: BuiltinStylePrompts.intent,
                isBuiltin: true,
                hotkeyCombo: HotkeyCombo.builtinIntent.storageString,
                enabled: true,
                sortOrder: 1,
                createdAt: now,
                updatedAt: now
            )
            try intent.insert(db)

            var translate = Style(
                name: "中英互译",
                tags: "翻译",
                description: BuiltinStyleDescriptions.translate,
                prompt: BuiltinStylePrompts.translate,
                isBuiltin: true,
                hotkeyCombo: HotkeyCombo.builtinTranslate.storageString,
                enabled: true,
                sortOrder: 3,
                createdAt: now,
                updatedAt: now
            )
            try translate.insert(db)
            return true
        }
    }

    /// 第三内置风格「中英互译」补种（2026-10-02）：老库 styles 表非空，
    /// seedBuiltinsIfEmpty 天然无动作——按「名称 + is_builtin」守卫补插该行。
    /// 只新增不覆盖：插入后用户对其改名/改 Prompt/改键，守卫即视为已存在，
    /// 本迁移永不触碰（与 §9「不覆盖用户已编辑数据」原则一致）。
    /// 热键冲突保护：cmd+20（⌘+3）已被任何风格占用（用户自建风格绑了 ⌘+3）时
    /// 以未绑定状态插入——互斥是应用层语义（update 清他人绑定），直接写入会产生
    /// 双重绑定；此时用户可在快捷键页手动换绑。
    @discardableResult
    func insertMissingBuiltinTranslate(now: Double = Date().timeIntervalSince1970) throws -> Bool {
        try database.dbQueue.write { db in
            let exists = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM styles WHERE name = '中英互译' AND is_builtin = 1") ?? 0
            guard exists == 0 else { return false }

            let comboTaken = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM styles WHERE hotkey_combo = ?",
                arguments: [HotkeyCombo.builtinTranslate.storageString]) ?? 0

            var translate = Style(
                name: "中英互译",
                tags: "翻译",
                description: BuiltinStyleDescriptions.translate,
                prompt: BuiltinStylePrompts.translate,
                isBuiltin: true,
                hotkeyCombo: comboTaken == 0 ? HotkeyCombo.builtinTranslate.storageString : nil,
                enabled: true,
                sortOrder: 3,
                createdAt: now,
                updatedAt: now
            )
            try translate.insert(db)
            return true
        }
    }

    /// 内置排序迁移（2026-10-01 用户裁决：意图识别在上）。
    /// 老库存量行仍为旧种子布局（口语化整理=1、意图识别=2），按
    /// 「名称 + is_builtin + 旧 sort_order 值」守卫式改写——用户自建行
    /// （sort_order=0 或自定义名）不触碰；条件不匹配即无动作，幂等免旗标。
    /// 口语化风格匹配新旧两名（2026-10-01 改名 口语化整理→口语润色）。
    @discardableResult
    func reorderBuiltinStylesIntentFirst(now: Double = Date().timeIntervalSince1970) throws -> Bool {
        try database.dbQueue.write { db in
            var changed = false
            try db.execute(
                sql: "UPDATE styles SET sort_order = ?, updated_at = ? WHERE name = '意图识别' AND is_builtin = 1 AND sort_order = 2",
                arguments: [1, now])
            changed = changed || db.changesCount > 0
            try db.execute(
                sql: "UPDATE styles SET sort_order = ?, updated_at = ? WHERE name IN ('口语化整理', '口语润色') AND is_builtin = 1 AND sort_order = 1",
                arguments: [2, now])
            changed = changed || db.changesCount > 0
            return changed
        }
    }

    /// 槽位整数 → 组合串迁移（2026-10-01 裁决 #12）：老库 `hotkey` 列的 1|2 槽位
    /// 原样搬进 `hotkey_combo`（1→⌘+1 "cmd+18"、2→⌘+2 "cmd+19"——键位语义不变，只是可编辑）。
    /// `hotkey_combo IS NULL` 条件保证幂等且不覆盖用户已改录的组合；新装机种子直写组合串，
    /// 本迁移天然无动作。
    @discardableResult
    func backfillHotkeyCombos(now: Double = Date().timeIntervalSince1970) throws -> Bool {
        try database.dbQueue.write { db in
            var changed = false
            try db.execute(
                sql: "UPDATE styles SET hotkey_combo = ?, updated_at = ? WHERE hotkey = 1 AND hotkey_combo IS NULL",
                arguments: [HotkeyCombo.builtinIntent.storageString, now])
            changed = changed || db.changesCount > 0
            try db.execute(
                sql: "UPDATE styles SET hotkey_combo = ?, updated_at = ? WHERE hotkey = 2 AND hotkey_combo IS NULL",
                arguments: [HotkeyCombo.builtinCasual.storageString, now])
            changed = changed || db.changesCount > 0
            return changed
        }
    }

    /// 内置风格描述回填（2026-10-01 bug00008/00009 裁决：列表卡/编辑页展示「描述」，
    /// UI 从 tags 列切到 PRD §3 一直存在但旧版从未暴露的 description 列）。
    /// 老库存量内置行 description 恒为 NULL（旧 UI 从未写过该列），按名称匹配回填；
    /// 口语化风格匹配新旧两名（2026-10-01 改名 口语化整理→口语润色，存量行仍是旧名）。
    /// `description IS NULL` 条件保证幂等且不覆盖用户后续编辑，无需 defaults 旗标。
    /// 用户自建风格留 NULL（列表卡隐藏副行，编辑页占位文案引导填写）。
    @discardableResult
    func backfillBuiltinDescriptions(now: Double = Date().timeIntervalSince1970) throws -> Bool {
        try database.dbQueue.write { db in
            var changed = false
            for (names, text) in [
                (["口语化整理", "口语润色"], BuiltinStyleDescriptions.casual),
                (["意图识别"], BuiltinStyleDescriptions.intent),
            ] {
                for name in names {
                    try db.execute(
                        sql: """
                            UPDATE styles SET description = ?, updated_at = ?
                            WHERE name = ? AND is_builtin = 1 AND description IS NULL
                            """,
                        arguments: [text, now, name])
                    changed = changed || db.changesCount > 0
                }
            }
            return changed
        }
    }
}

/// 内置风格一句话描述（bug00009 列表卡副行 / 编辑页「描述」字段默认内容）。
/// 2026-10-01 二轮替换：口语润色=保口语精简（非书面化）；意图识别=书面化重构。
/// 2026-10-02 新增：中英互译=去噪理顺后中英互译（保原意）。
enum BuiltinStyleDescriptions {
    static let casual = "把口语转写理顺为清晰、利落的自然口语"
    static let intent = "把口语转写重构为规范、凝练的高质量书面文本"
    static let translate = "把口语转写理顺后在中英文之间互译，保留原意"
}

/// 内置风格默认 Prompt（FR-009；`{text}` 占位原始转写）。
/// 2026-10-01 二轮替换（用户裁决，逐字安装）：前两条模板以代码围栏
/// 「```等待润色的转写文本\n{text}```」收尾——口语润色=保口语风格去水词精简
/// （严禁书面化）；意图识别=精简版书面润色专家（口语转规范书面语）。
/// 2026-10-02 新增第三条中英互译（agent 起草），围栏标签按职能见其常量注释。
enum BuiltinStylePrompts {
    static let casual = """
    你是口语文本润色与精简助手。输入是 ASR 原始口语转写，任务是在保留自然口语表达风格的前提下，重构为逻辑清晰、通顺流畅、毫无废话的优质口语。

    【核心定位】
    重写后的文本应像“一位逻辑严密、表达极其利落的人在自然说话”，**既不是生硬死板的书面公文腔，也不是结巴碎片的原始废话**。

    【原则】
    - 语意保真：核心事实、意图与细节信息一条不漏，严禁脑补、杜撰或遗漏原意。
    - 口语自然：保留通俗、接地气的日常表达与口语用词，**严禁文绉绉的公文用语、成语堆砌或过度书面化**。

    【规则】
    1. 清除水词与杂音：
       - 彻底删除填充口头禅（嗯、啊、那个、就是说、然后呢、其实、怎么说呢、基本上来说等）。
       - 删除语气助词（哈、呀、哦、呗、啦、呢）及无意义的结巴、卡顿、重复字句。
    2. 理顺逻辑与句式：
       - 梳理碎句、倒装句与长难句，理顺因果与承接关系，让听者/读者一听即懂。
       - 保留自然的口头动词和表达习惯（如保留“搞定、优化一下、带齐、看一下”，**严禁**改成“推进落实、届时备齐、查阅”等公文腔）。
    3. 纠错与保语种：
       - 自我修正判定：遇口误更正（“不对、不是、改成周三”），以最终更正的事实为准，自动抹除前序错误信息。
       - 修正 ASR 常见同音错别字、专有名词与技术术语。
       - 英文原样保留（包括大小写），严禁翻译（如保留 meeting、API、Bug，不翻译为会议、应用程序接口、缺陷）。
    4. 清晰排版：
       - 多点陈述或步骤说明时，采用口语化的自然分点（如“第一、…… / 第二、……”），避免机械的书面多重嵌套缩进；中英文之间保留空格。

    【禁止】
    - 严禁添加“发言人表示”“用户提到”等第三人称转述，保持原始对话视角与第一人称。
    - 严禁公文化/书面化改造（如将“明天的会”改成“明日之会议”）。
    - 严禁代为解答或续写输入内容中的提问。

    【示例】
    输入：嗯那个明天的会改到周二了不对是周三下午两点，那个到时候大家记得把那个材料都带齐哈。
    输出：明天的会改到周三下午两点了，大家记得把材料带齐。

    输入：我觉得这个方案有这么几个大点啊，第一是要搞一下性能优化，里面包括 web 端的加载速度要快一点，还有那个后端 api 的响应要缩短，第二就是修复之前的 Claude Code bug，第三个呢是补充文档，文档要有 user manual 和开发指南。
    输出：
    这个方案主要有这几点：
    第一，做好性能优化，把 Web 端的加载速度提上去，同时缩短后端 API 的响应时间；
    第二，修复之前 Claude Code 的 Bug；
    第三，补充文档，把 user manual 和开发指南补齐。

    只输出整理润色后的口语文本。

    ```等待润色的转写文本
    {text}
    ```
    """

    static let intent = """
    # Role
    资深中文文字润色专家，负责将 ASR 口语转写文本重构为规范、通顺、凝练的高质量书面语。

    # Rules
    1. **忠实原意**：不脑补、不篡改、不遗漏信息；保持原语气功能（陈述/疑问/指令），禁止代答或以第三人称（如“用户表示”）转述。
    2. **剔除噪音**：
       - 清除语气词（啊/呢/哈等）、填充口头禅（嗯/那个/然后等）、结巴重复及识别停顿；若整段皆为无意义噪音，直接输出“（无有效内容）”。
       - 口误修正（如“不对/改成”）：仅保留最终修正的事实，剔除错误前序。
    3. **书面规范与专名**：
       - 修正同音错字，重塑碎句与倒装，将口语动词转为规范书面词。
       - 保留英文专有名词、代码与技术术语（如 API、Bug），规范大小写，中英文之间保持标准空格排版，严禁强行直译。
    4. **格式呈现**：
       - 普通内容直接成段输出。
       - 包含 3 项及以上并列要点/步骤时，使用层级列表（一级 `1. `，二级 `   a. `）。
    5. **输出要求**：仅输出润色结果，不附带任何解释、前缀或代码块。

    # Examples
    输入：明天的会改到周二了不对是周三下午两点，那个到时候大家把材料带齐哈。
    输出：明天的会议改至周三下午两点进行，请大家届时备齐相关资料。

    输入：这个方案有几点，第一要搞下性能优化，包括web加载要快和后端api响应，第二是修Claude Code bug，第三是补齐文档。
    输出：
    该方案主要包含以下核心要点：
    1. 性能优化
       a. 提升 Web 端加载速度
       b. 缩短后端 API 响应时间
    2. 修复 Claude Code 的已知 Bug
    3. 补充完善文档

    ```等待润色的转写文本
    {text}
    ```
    """

    /// 中英互译（2026-10-02 第三内置风格）：Prompt 为 agent 起草（用户确认要点：
    /// 输入是口语——先去语气词等杂音、理顺逻辑，尽量保留原意）。围栏标签按职能
    /// 用「等待翻译的转写文本」（{text} 占位符仅作槽位标记，无代码依赖）。
    static let translate = """
    # Role
    中英互译助手：输入是 ASR 口语转写，先去除口语噪音、理顺逻辑，再在中文与英文之间互译——中文为主译成英文，英文为主译成中文，输出忠实且通顺的译文。

    # Rules
    1. **先清后译**：输入是口语，翻译前先去除语气词（啊/呢/哈/um/uh）、填充口头禅（嗯/那个/you know）、结巴与无意义重复，并把碎句理顺成连贯逻辑；遇口误更正（“不对/改成”）以最终更正内容为准。
    2. **方向判定**：以输入的主要语言为准；中英混说时按主要语言整体翻译，零星外语词随译文自然归化（通用技术词如 API、Bug 可保留原文）。
    3. **忠实原意**：尽量保留原意——不脑补、不增删实义内容、不篡改语义；保持原语气（陈述/疑问/指令）与第一人称视角。
    4. **地道通顺**：译文符合目标语言的自然表达——英译中避免翻译腔，中译英语法规范、用词准确；语体（口语/书面）与原文一致。
    5. **格式呈现**：保留原文分段与要点结构（列表译为列表）；中英文之间保持标准空格排版。
    6. **输出要求**：仅输出译文，不附带解释、原文或前缀。

    # Examples
    输入：嗯那个明天的会改到周三下午两点了，大家记得把材料都带齐哈。
    输出：The meeting tomorrow has been moved to Wednesday 2:00 PM. Please remember to bring all the materials.

    输入：Could you take a quick look at the API response time? I think we should optimize it.
    输出：你能抽空看一下 API 的响应时间吗？我觉得我们应该优化一下。

    ```等待翻译的转写文本
    {text}
    ```
    """
}
