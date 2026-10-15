import SwiftUI

/// 听写模型设置页（2026-10-06 两级化，定稿原型 docs/design-demos/ai-service-providers.html，
/// 对齐 AI 服务页 TASK-091 模式）：
/// 一级 = API/本地模型分段 + 五张供应商卡（名称 + 密钥/模型 chips +「✓ 使用中」chip +
/// 描述 + 「使用」图标钮 + ›，TASK-146 图标语言对齐本地卡）；点卡片本体进二级
/// （页内整页替换，StyleList→StyleEditor 先例）。
/// 二级 = 该供应商配置表单：「服务配置」卡（Base URL 五家可编辑 / API Key 三态 /
/// 模型预设下拉 + 自定义模型 ID 分离，TASK-098 同款）+「听写参数」卡按能力矩阵
/// （语言提示 / 即时热词 / 方言保留，无能力者显说明行）+ 测试连接 + 保存。
/// 「当前使用」只在一级卡「使用」切换（保存不切换服务）；Key 按供应商分存 Keychain；
/// 配置按供应商分键（AppSettings.asr*(for:)），互不覆盖。
/// 语言提示/热词/方言为全局参数（语义上仅当前听写服务商消费），即改即生效不经「保存」。
/// 同形脚手架与纯逻辑自 TASK-117 起在 ProviderSettingsSupport 单一来源（本页特有的
/// API/本地分段与听写参数卡留在本文件）。
struct ASRSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    /// 二级页态：nil = 一级列表（页内整页替换，非导航 push）。
    @State private var selectedProvider: AppSettings.ASRProvider?
    /// 本地镜像（bug00013 铁律：AppSettings 非 Observable，卡片选中态即时刷新靠它）。
    @State private var currentProvider: AppSettings.ASRProvider = .qwen
    @State private var keyStates: [AppSettings.ASRProvider: Bool] = [:]
    /// 分段纯视图（2026-10-11 原型定稿：切分段**不切引擎**；nil = 未初始化，
    /// onAppear 首次随当前引擎定分支，之后由用户切换）。
    @State private var viewMode: AppSettings.ASRMode?
    /// 引擎镜像（「使用中」互斥的唯一仲裁：API 与本地只能一个——只随两侧
    /// 「使用」动作更新，与 settings.asrMode 双写驱动重绘）。
    @State private var engineMode: AppSettings.ASRMode = .api
    /// 本地活跃模型镜像（引擎状态条显示 + 本地卡选中高亮共用；本地「使用」双写）。
    @State private var activeLocalModelID: String?
    /// 「使用」前置测试进行中的供应商（TASK-120 先测后切；nil = 无在跑测试）。
    @State private var useTestingProvider: AppSettings.ASRProvider?
    /// 待确认删除的本地模型（TASK-143 居中模态；nil = 无）。
    @State private var pendingDelete: LocalModelInfo?
    /// Esc 本地监听（模态在挂时拦截 Esc 取消；卸载于模态收起）。
    @State private var escMonitor: Any?

    /// 当前分段视图（nil 未初始化时回落引擎分支）。
    private var displayedMode: AppSettings.ASRMode { viewMode ?? engineMode }

    var body: some View {
        Group {
            if let provider = selectedProvider {
                ASRProviderDetailView(
                    provider: provider,
                    onBack: { selectedProvider = nil }
                )
            } else {
                providerList
            }
        }
    }

    // MARK: - 一级页 · 供应商列表

    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                // 引擎状态条（2026-10-11 原型定稿上移：分段上方、两分支共享；
                // 本地引擎亮蓝高亮，右端内存监控仅本地 Tab 显示）
                EngineStatusBar(
                    engineMode: engineMode,
                    activeLocalModelID: activeLocalModelID,
                    currentProvider: currentProvider,
                    isLocalTab: displayedMode == .local,
                    onUnload: { environment.localSession.unload() })
                // TASK-142（bench 原型 tabrow）：分段旁 rangeline 提示行，随分支切换
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    modeSegment
                    Text(displayedMode == .local
                        ? LocalizedStringKey("models.local.range.local")
                        : LocalizedStringKey("models.local.range.api"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.top, 14) // 状态条 → 分段行（原型 tabrow margin-top:14）
                .padding(.bottom, 8)

                if displayedMode == .local {
                    // 本地模型分支（TASK-134 原型落地：运行时横幅 + 三组卡片；
                    // 引擎/活跃模型镜像经 Binding 上提——本地「使用」即时刷新状态条。
                    // 删除请求上提：TASK-143 二次确认模态由本页收口）
                    LocalModelsSection(
                        engineMode: $engineMode,
                        activeModel: $activeLocalModelID,
                        onRequestDelete: { pendingDelete = $0 })
                } else {
                    // 互斥可视化（原型 pnote）：引擎走本地时浏览 API 分支——
                    // 无任何「使用中」，横幅点明当前引擎与切换路径
                    if engineMode == .local {
                        Text("models.api.localengine.hint")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text2)
                            .lineSpacing(4)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.blueTintBg))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.blueTintBorder, lineWidth: 1))
                            .padding(.top, 10)
                    }
                    VStack(spacing: 20) { // TASK-145：卡间 20pt 对齐本地模型卡（10+10 叠加基准）
                        ForEach(AppSettings.ASRProvider.allCases, id: \.self) { provider in
                            providerCard(provider)
                        }
                    }
                    // TASK-145 追记：互斥横幅在显时 → 首卡同 20pt 节奏（用户截图指认 4pt 过挤）；
                    // 无横幅（引擎走 API）分段行 → 首卡维持 8+4=12pt
                    .padding(.top, engineMode == .local ? 20 : 4)

                    Text("models.providers.hint")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .lineSpacing(4)
                        .padding(.top, 12)
                }
            }
            // TASK-077/080：三层居中限宽（max 800 / 水平 22 / 顶 48 / 底 16）
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 48) // TASK-082：顶部 ×3
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            // 从二级页返回时重新刷新（Key/模型可能已保存变更）；
            // viewMode 不重置——用户手动切过分段，返回时保持所在视图
            currentProvider = environment.settings.asrProvider
            engineMode = environment.settings.asrMode
            if viewMode == nil { viewMode = environment.settings.asrMode }
            activeLocalModelID = environment.settings.activeLocalModel
            refreshKeyStates()
            applyDebugDetailArgument()
            applyDebugUseProbeArgument()
            applyDebugLocalArgument()
            applyDebugDeleteConfirmArgument()
        }
        .overlay {
            // TASK-143 删除二次确认（居中模态，原型形态 A）：遮罩点击/Esc 取消
            if let model = pendingDelete {
                LocalModelDeleteConfirm(
                    model: model,
                    onCancel: { pendingDelete = nil },
                    onConfirm: { confirmDelete(model) })
            }
        }
        .animation(.easeInOut(duration: 0.18), value: pendingDelete)
        .onChange(of: pendingDelete) { _, newValue in
            syncEscMonitor(isActive: newValue != nil)
        }
        // `--local-models-bottom`（页尾实测口径脚注截图用）随脚注整体退役
        // （2026-10-14 用户裁决移除脚注；ScrollViewReader 包装一并退场）
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) { // TASK-082：标题↔副标题 3→6
            Text("models.title")
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Theme.text1)
            Text("models.desc")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(4)
        }
        .padding(.bottom, 10)
    }

    /// API / 本地模型分段（2026-10-11 原型定稿：**纯视图切换**——不写引擎；
    /// 引擎只随两侧「使用」按钮变化，任一时刻 API 与本地只能一个「使用中」）。
    /// equalWidth（2026-10-12 用户裁决）：两段药丸取最宽文案（本地模型）等宽，
    /// 「API」框不再明显窄于本地框。
    private var modeSegment: some View {
        GlassSegmented(
            options: [AppSettings.ASRMode.api, .local],
            selection: Binding(
                get: { displayedMode },
                set: { viewMode = $0 }),
            equalWidth: true,
            label: { $0 == .api ? String(localized: "models.mode.api") : String(localized: "models.mode.local") }
        )
    }

    /// 供应商卡（共享件 ProviderListCard；TASK-146 起按钮为图标语言，文案键归共享件）。
    /// isCurrent 含引擎判定（2026-10-11 互斥修复）：engineMode == .api 才可能
    /// 「使用中」——本地模型使用中时 API 卡一律不显（用户报的「同时使用中」bug）。
    private func providerCard(_ provider: AppSettings.ASRProvider) -> some View {
        ProviderListCard(
            name: provider.displayName,
            cardDescription: provider.cardDescription,
            isCurrent: provider == currentProvider && engineMode == .api,
            hasKey: keyStates[provider] == true,
            modelChip: environment.settings.asrModel(for: provider),
            useTesting: provider == useTestingProvider,
            useDisabled: useTestingProvider != nil,
            onUse: { use(provider) },
            onOpen: { selectedProvider = provider })
    }

    /// 「使用」切换当前听写服务（TASK-120 用户裁决：先测后切）——对目标家**已保存**
    /// 配置跑一次内置 MP3 探针转写（与二级页「测试连接」同链路，emptyResult 仍视为
    /// 链路通），通过才切换（本地镜像 + settings 双写，立即对下一次听写生效）；失败
    /// 不落任何写入，弹全站 Toast（灰色 ↻ 固定短文案）。保存语义不受影响（AGENTS §41）。
    /// 「使用中」显示门槛 = 当前且已配 Key（§41 追裁）——未配 Key 的当前家按钮照常
    /// 显示「使用」，点击走同一测试链路（通过即回使用中态），故不设 current 排除。
    private func use(_ provider: AppSettings.ASRProvider) {
        guard useTestingProvider == nil else { return }
        guard let config = ProviderSettingsSupport.savedASRConfig(
            provider: provider,
            settings: environment.settings,
            secrets: environment.secrets) else {
            environment.toast.show(ProviderSettingsSupport.useBlockedToastText, info: true)
            return
        }
        useTestingProvider = provider
        // 探针直走 API 引擎（勿换 asrEngine：ActiveASREngine 按当前模式路由，
        // 本地模式下会误发本地引擎——测不到目标供应商，本地 runtime 缺失时
        // 还会以 localRuntimeMissing 误拦切换）
        let engine = environment.apiASREngine

        Task.detached {
            // let + 全分支定赋值：捕获不可变值跨并发边界（旧 var ok 写法在
            // Swift 6 模式下是错误）
            let ok: Bool
            do {
                let probe = try TestProbeAudio.bundledURL()
                _ = try await engine.transcribe(audioFileAt: probe, config: config)
                ok = true
            } catch let error as ASRError where error == ASRError.emptyResult {
                // 兜底：探针被判无语音（emptyResult）仍视为链路通（服务应答正常，
                // 与二级页测试同语义）。
                ok = true
            } catch {
                ok = false
            }
            if ok {
                AppLog.pipeline.info("asr use probe ok provider=\(provider.rawValue, privacy: .public)")
            } else {
                AppLog.pipeline.error("asr use probe failed provider=\(provider.rawValue, privacy: .public)")
            }
            await MainActor.run {
                useTestingProvider = nil
                if ok {
                    currentProvider = provider
                    environment.settings.asrProvider = provider
                    // 任一侧点「使用」即切引擎（原型互斥语义）：API 使用 → 引擎转 API；
                    // 分段视图不动（用户已在 API 分支）。切 API 即时卸载本地 worker
                    // 释放内存（用户裁决 2026-10-11，不等 5 分钟空闲；下次本地
                    // 转写惰性重载）。
                    engineMode = .api
                    environment.settings.asrMode = .api
                    environment.localSession.unload()
                    // 探测通过意味着 Key 实际在位——刷新 chips，防 keyStates 陈旧时
                    // 使用中门槛（当前且已配 Key）把卡片误留在「使用」。
                    refreshKeyStates()
                } else {
                    environment.toast.show(ProviderSettingsSupport.useBlockedToastText, info: true)
                }
            }
        }
    }

    private func refreshKeyStates() {
        keyStates = ProviderSettingsSupport.keyStates(
            providers: AppSettings.ASRProvider.allCases,
            account: SecretAccount.asrAccount(for:),
            secrets: environment.secrets)
    }

    // MARK: - 删除二次确认（TASK-143，居中模态）

    /// 确认删除：成功弹窗口正中 Toast（「已删除 <名> · 释放约 X」绿 ✓，原型对齐）；
    /// 失败走 info Toast（deleteInstalled 抛错即目录在——罕见，落库无变更）。
    private func confirmDelete(_ model: LocalModelInfo) {
        defer { pendingDelete = nil }
        do {
            try environment.localModels.deleteInstalled(model.id)
            environment.toast.show(String(
                format: String(localized: "models.local.delete.toast"),
                model.name, LocalModelCatalog.sizeText(model.sizeBytes)))
        } catch {
            environment.toast.show(
                String(localized: "models.local.delete.failed"),
                info: true)
        }
    }

    /// 模态在挂时本地拦截 Esc（keyCode 53）取消；收起即卸载监听。
    /// 本地 monitor 只影响本 App 事件流，与全局热键 CGEventTap 无关。
    private func syncEscMonitor(isActive: Bool) {
        if isActive, escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                pendingDelete = nil
                return nil
            }
        } else if !isActive, let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    /// Debug 自动化：`--local-delete-confirm` 预置删除确认模态（TASK-143 截图/走查用；
    /// 取 q068 作待删模型——默认未安装也不影响弹窗形态本身）。
    private func applyDebugDeleteConfirmArgument() {
        #if DEBUG
        guard CommandLine.arguments.contains("--local-delete-confirm") else { return }
        viewMode = .local
        pendingDelete = LocalModelCatalog.model(id: "mlx-community/Qwen3-ASR-0.6B-8bit")
        #endif
    }

    /// Debug 自动化：`--local-models` 直达「本地模型」分段（TASK-134 截图/走查用；
    /// 运行时安装/下载的自动化在 AppDelegate 启动链，不依赖窗口可见）。
    /// 2026-10-11 起分段纯视图化：只切视图不写引擎。
    /// `--api-tab`（TASK-145 追记）直达「API」分段——互斥横幅（引擎本地 + 视图 API）
    /// 经 defaults 态天然到不了（onAppear viewMode 跟随 asrMode），只能在此强制。
    private func applyDebugLocalArgument() {
        #if DEBUG
        if CommandLine.arguments.contains("--local-models") { viewMode = .local }
        if CommandLine.arguments.contains("--api-tab") { viewMode = .api }
        #endif
    }

    /// Debug 自动化：`--asr-detail` 直接进入当前供应商的二级页（截图/走查脚本用，
    /// 与 `--llm-detail` 同款机制；仅 Debug 编译进二进制）。
    private func applyDebugDetailArgument() {
        #if DEBUG
        guard CommandLine.arguments.contains("--asr-detail") else { return }
        selectedProvider = environment.settings.asrProvider
        #endif
    }

    /// Debug 自动化：`--asr-use-custom` 自动对 custom 家触发「使用」前置探测
    /// （TASK-120 失败路径截图/走查用——合成点击需辅助功能权限，此入口零权限
    /// 即可拍「测试中…」/Toast 瞬态；仅 Debug 编译进二进制）。
    private func applyDebugUseProbeArgument() {
        #if DEBUG
        guard CommandLine.arguments.contains("--asr-use-custom") else { return }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000) // 等视图挂稳再触发
            use(.custom)
        }
        #endif
    }
}

// MARK: - 引擎状态条（2026-10-11 原型定稿：分段上方 · 两分支共享）

/// 「当前听写引擎」状态条——engine 唯一仲裁「使用中」互斥：engine=local 显本地
/// 模型（亮蓝高亮 + 蓝点脉冲），否则显 API 供应商/模型（中性灰 + 离线引导 hint）。
/// 本地 Tab 右端追加资源监控（worker 进程 CPU · 内存；未加载显灰色占位）。
private struct EngineStatusBar: View {
    @Environment(AppEnvironment.self) private var environment

    let engineMode: AppSettings.ASRMode
    let activeLocalModelID: String?
    let currentProvider: AppSettings.ASRProvider
    let isLocalTab: Bool
    /// 「卸载」按钮回调（仅释放内存；引擎与 activeLocalModel 不动——用户裁决 2026-10-11）。
    var onUnload: () -> Void = {}

    private var localOn: Bool {
        guard let id = activeLocalModelID,
              LocalModelCatalog.model(id: id) != nil,
              environment.localModels.isInstalled(id) else { return false }
        return engineMode == .local
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("models.local.stat.label")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)

            if localOn, let model = LocalModelCatalog.model(id: activeLocalModelID ?? "") {
                HStack(spacing: 8) {
                    PulsingDot(dot: Theme.blue, halo: Theme.blueTintBg)
                    Text("models.local.stat.local") + Text(" ") + Text(model.name).fontWeight(.semibold)
                    Text("\(model.quant) · mlx-audio")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text2)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.blue)
            } else {
                HStack(spacing: 8) {
                    PulsingDot(dot: Theme.green, halo: Theme.greenTintBg)
                    Text("API · ").fontWeight(.semibold)
                        + Text(environment.settings.asrModel(for: currentProvider))
                        .font(Theme.mono(12))
                }
                .font(.system(size: 12.5))
                // 语义绿（浅 #15803d / 深 #5fd577）：亮绿 #30d158 压淡绿底在浅色
                // 主题下不可读（2026-10-11 用户红框实机反馈）；圆点维持亮绿装饰色
                .foregroundStyle(Theme.ok)
            }

            Spacer(minLength: 8)
            if isLocalTab {
                WorkerResourceMonitor(onUnload: onUnload)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(localOn ? Theme.blueTintBg : Theme.greenTintBg))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(localOn ? Theme.blueTintBorder : Theme.greenTintBorder, lineWidth: 1))
        .padding(.top, 16)
    }
}

/// 引擎呼吸点（外圈光晕——原型 dot-pulse 动画对应；本地=蓝、API=绿）。
private struct PulsingDot: View {
    let dot: Color
    let halo: Color
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(halo)
                .frame(width: 15, height: 15)
                .opacity(pulsing ? 0.9 : 0.25)
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

/// 资源监控（仅本地 Tab）：worker 进程 CPU · 内存 ~1s 轮询；进程未运行（惰性加载
/// 未启动 / 空闲 5 分钟自动卸载 / 手动「卸载」后）显灰色占位「模型未加载」
/// （2026-10-12 追裁七：槽位常驻防「读数凭空消失」误判；§73 形态更新：有值显
/// 「CPU xx% · 内存 x.xx GB」）；「卸载」按钮仅释放内存、引擎保持本地。
/// CPU = 两次采样累计 CPU 时间差 ÷ 墙钟差 ÷ 逻辑核数（0–100 归一）。
private struct WorkerResourceMonitor: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var residentBytes: Int64?
    @State private var cpuPercent: Int?
    /// 上一拍基线（墙钟 + 累计 CPU 时间），CPU 差分用。
    @State private var lastSample: (wallNanos: Int64, cpuNanos: Int64)?
    @State private var pollingTask: Task<Void, Never>?
    var onUnload: () -> Void = {}

    var body: some View {
        Group {
            if let residentBytes {
                HStack(spacing: 10) {
                    (Text("models.local.cpu.label")
                        .foregroundStyle(Theme.text3)
                        + Text(" \(cpuPercent.map { "\($0)%" } ?? "--%")")
                            .font(Theme.mono(12))
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.text1)
                        + Text(" · ")
                            .foregroundStyle(Theme.text3)
                        + Text("models.local.mem.label")
                            .foregroundStyle(Theme.text3)
                        + Text(" \(Self.text(residentBytes))")
                            .font(Theme.mono(12))
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.text1))
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                    Button("models.local.unload") { onUnload() }
                        .buttonStyle(.themeGhost)
                        .controlSize(.small)
                }
            } else {
                // 未加载占位（追裁七，§73 形态更新）：worker 不在跑的三个正常时段
                // 统一形态，槽位常驻防「读数凭空消失」误判；无卸载按钮。
                Text("models.local.mem.unloaded")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .onAppear(perform: startPolling)
        .onDisappear { pollingTask?.cancel() }
    }

    private static func text(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    /// 轮询 Task 继承 View 的 @MainActor 隔离，整体在主线程跑（proc_pidinfo/
    /// NSLock 皆轻量操作，1s 一次无压力）；MainActor.run 是隔离变化时的兜底跳转。
    private func startPolling() {
        pollingTask?.cancel()
        let session = environment.localSession
        pollingTask = Task {
            while !Task.isCancelled {
                let snapshot = session.workerSnapshot
                let wall = DispatchTime.now().uptimeNanoseconds
                guard !Task.isCancelled else { return }
                await MainActor.run { apply(snapshot: snapshot, wallNanos: wall) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// 单拍落地：写读数 + 用上一拍基线差分出 CPU%。累计时间回退（worker 重启，
    /// 新进程从零计）→ 丢弃旧基线、本拍 CPU 显「--%」，下一拍恢复。
    private func apply(snapshot: ProcessMemory.Snapshot?, wallNanos: UInt64) {
        residentBytes = snapshot?.residentBytes
        if let snapshot, let last = lastSample, snapshot.totalCPUNanos >= last.cpuNanos {
            cpuPercent = ProcessMemory.cpuPercent(
                cpuDeltaNanos: snapshot.totalCPUNanos - last.cpuNanos,
                wallDeltaNanos: Int64(bitPattern: wallNanos) - last.wallNanos
            ).map { Int($0.rounded()) }
        } else {
            cpuPercent = nil
        }
        lastSample = snapshot.map {
            (wallNanos: Int64(bitPattern: wallNanos), cpuNanos: $0.totalCPUNanos)
        }
    }
}

/// 二级页 · 单供应商配置表单（沿 LLMProviderDetailView 骨构 + 听写参数卡；
/// 表单三层限宽同款：800 列 / 22 内距 / 顶 42（二级页标准））。
struct ASRProviderDetailView: View {
    @Environment(AppEnvironment.self) private var environment

    let provider: AppSettings.ASRProvider
    let onBack: () -> Void

    private typealias TestState = ProviderSettingsSupport.TestState

    /// 即时热词行（UI 保序；持久化为 [String: Int]）。
    private struct HotwordRow: Identifiable {
        let id = UUID()
        var word: String
        var weight: Int
    }

    /// 语言提示可选项（代码与显示名经 AppSettings.languageOptionLabel 统一）。
    static let languageCodes = ["zh", "en", "yue", "ja"]

    @State private var keyConfigured = false
    @State private var baseURLInput = ""
    @State private var presetModel = ""
    /// 下拉是否选「自定义模型」（TASK-098 分离交互；custom 端点无预设不走此态）。
    @State private var usesCustomModel = false
    @State private var customModelInput = ""
    /// 听写参数（全局键、即改即生效；镜像驱动重绘——bug00013 铁律）。
    @State private var languageHints: [String] = []
    @State private var hotwordRows: [HotwordRow] = []
    @State private var testState: TestState = .idle
    @State private var savedFlash = false
    @State private var savedFlashTask: Task<Void, Never>?
    @State private var isCurrent = false

    private var urlOK: Bool { provider.baseURLIsValid(baseURLInput) }

    /// 模型校验（TASK-098 用户裁决同款）：预设供应商选了「自定义模型」时 ID 必填；
    /// custom 端点（无预设）恒过（留空 = 不携带 model，行为同旧版）。
    private var modelOK: Bool {
        provider.modelPresets.isEmpty || !usesCustomModel
            || !customModelInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProviderDetailBackButton(titleKey: "models.back", action: onBack)
                ProviderDetailTitleRow(
                    name: provider.displayName, isCurrent: isCurrent, keyConfigured: keyConfigured)

                ProviderSectionLabel(key: "models.section.service", first: true)

                SettingsCard {
                    baseURLRow
                    keyRow
                    modelRow
                    if !provider.modelPresets.isEmpty {
                        customModelIDRow
                    }
                }

                ProviderSectionLabel(key: "models.section.params", first: false)

                SettingsCard {
                    paramsCardRows
                }

                bottomBar

                Text(detailHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineSpacing(4)
                    .padding(.top, 12)
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 42) // 二级页标准（StyleEditor 同款）
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: load)
    }

    // MARK: - 服务配置卡（共享行件；本页参数注入）

    /// Base URL（五家都可编辑——openai/groq/mistral 预填官方端点、custom 手填；
    /// hint 动态取自 ASRProviderCatalog，非法时红字——custom 的 http 放行文案不同，
    /// 且与 AI 服务页措辞有知情差异勿统一）。
    private var baseURLRow: some View {
        ProviderBaseURLRow(
            urlOK: urlOK,
            hint: urlOK ? provider.baseURLHint : invalidURLHint,
            placeholder: "https://your-asr-service.com/v1",
            text: $baseURLInput)
    }

    /// 非法提示按 provider 区分：custom（http 放行）与官方服务（https-only）文案不同。
    private var invalidURLHint: String {
        provider.allowsPlainHTTP
            ? String(localized: "models.baseurl.invalid.custom")
            : String(localized: "models.baseurl.invalid")
    }

    /// Debug 起始态门控：load()（含 keyConfigured 读出）完成后才置值传给组件。
    @State private var keyDebugStart: APIKeyField.DebugStart = .none

    /// API Key 三态字段（2026-10-03 原型定稿）：交互全在 APIKeyField/共享行件内；
    /// 本页只接 isConfigured 镜像 + 提交落盘（+10 chip 右移语义见共享件注释）。
    private var keyRow: some View {
        ProviderKeyRow(
            titleKey: "models.apikey",
            hintKey: "models.apikey.hint",
            isConfigured: keyConfigured,
            debugStart: keyDebugStart,
            keyPageURL: provider.apiKeyURL,
            onCommit: commitAPIKey)
    }

    /// 模型字段 placeholder（TASK-128 追裁：按家区分——四家有预设的供应商显各自
    /// 默认模型 ID，不再全站共用同一个 qwen 家 ID；custom 端点无已知各家模型，
    /// 回落通用文案键。与 LLM 页 modelIDPlaceholder 同构）。
    private var modelIDPlaceholder: LocalizedStringKey {
        provider.defaultModel.isEmpty
            ? "models.model.id.placeholder"
            : LocalizedStringKey(provider.defaultModel)
    }

    /// 模型行（TASK-098 分离交互；行标题/hint/placeholder 为本页文案——custom 端点
    /// 「模型名」沿用旧文案，与 LLM 页「模型」有知情差异勿统一）。
    private var modelRow: some View {
        ProviderModelRow(
            presets: provider.modelPresets,
            customTitle: String(localized: "models.model"),
            customHint: String(localized: "models.model.custom.hint"),
            customPlaceholder: modelIDPlaceholder,
            presetTitle: String(localized: "models.model.title"),
            presetHint: String(localized: "models.model.hint"),
            customOptionText: String(localized: "models.model.custom"),
            customModelInput: $customModelInput,
            presetModel: $presetModel,
            usesCustomModel: $usesCustomModel)
    }

    /// 自定义模型 ID 行（TASK-098 用户裁决：与下拉分离 + 禁用态常驻，详见共享件注释）。
    private var customModelIDRow: some View {
        ProviderCustomModelIDRow(
            title: String(localized: "models.model.customid"),
            hint: String(localized: "models.model.customid.hint"),
            emptyKey: "models.model.customid.empty",
            placeholder: modelIDPlaceholder,
            modelOK: modelOK,
            usesCustomModel: usesCustomModel,
            customModelInput: $customModelInput)
    }

    // MARK: - 听写参数卡（按能力矩阵；语言/热词用 stack 行满宽，方言标准行）

    /// 行序：语言提示 → 即时热词 → 方言保留；无任何能力 → 一行说明（原 capsNoneNote）。
    @ViewBuilder private var paramsCardRows: some View {
        if provider.supportsLanguageHints {
            languageRow(divider: provider.supportsHotwords || provider.supportsDialect)
        }
        if provider.supportsHotwords {
            hotwordRow(divider: provider.supportsDialect)
        }
        if provider.supportsDialect {
            SettingRow("models.dialect", divider: false) {
                GlassToggle(isOn: dialectBinding)
            }
        }
        if !provider.supportsLanguageHints && !provider.supportsHotwords && !provider.supportsDialect {
            capsNoneNote
        }
    }

    /// 语言提示 chips（最多 4 项；qwen 按顺序作 language_hints，兼容系作 prompt 前缀）。
    private func languageRow(divider: Bool) -> some View {
        SettingStackRow("models.langs", hint: languageHint, divider: divider) {
            HStack(spacing: 7) {
                ForEach(Self.languageCodes, id: \.self) { code in
                    languageChip(code)
                }
                Spacer()
            }
        }
    }

    private var languageHint: LocalizedStringKey {
        provider == .qwen ? "models.langs.hint.qwen" : "models.langs.hint.compat"
    }

    private func languageChip(_ code: String) -> some View {
        let on = languageHints.contains(code)
        return Button {
            toggleLanguage(code)
            testState = .idle
        } label: {
            Text((on ? "✓ " : "") + (AppSettings.languageOptionLabel(for: code) ?? code))
                .font(.system(size: 12.5))
                .foregroundStyle(on ? Theme.text1 : Theme.text2)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.blueTintBg : Theme.fillSoft))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Theme.blueTintBorder : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 语言提示开关：最多 4 项（可选项总数即 4，天然不超）；本地态 + settings 双写。
    private func toggleLanguage(_ code: String) {
        if languageHints.contains(code) {
            languageHints.removeAll { $0 == code }
        } else {
            languageHints.append(code)
        }
        environment.settings.languageHints = languageHints
    }

    /// 即时热词表格（v2-glass：词/权重表头 + 行内编辑 + 权重下拉 + × 删除 + 添加热词）。
    private func hotwordRow(divider: Bool) -> some View {
        SettingStackRow("models.hotwords", hint: "models.hotwords.hint", divider: divider) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("models.hotwords.col.word")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Text("models.hotwords.col.weight")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 76, alignment: .leading)
                    Color.clear.frame(width: 24)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.fillSoft)

                ForEach(hotwordRows) { row in
                    hotwordLine(row)
                }

                HStack {
                    Button("models.hotwords.add") { addHotword() }
                        .buttonStyle(.themeGhost)
                        .controlSize(.small)
                        .disabled(hotwordRows.count >= 50)
                    Spacer()
                    if hotwordRows.count >= 50 {
                        Text("models.hotwords.limit")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.top, 4)
        }
    }

    private func hotwordLine(_ row: HotwordRow) -> some View {
        HStack(spacing: 8) {
            TextField("models.hotwords.placeholder", text: hotwordWordBinding(row.id))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            Spacer()
            weightMenu(row.id)
            Button {
                removeHotword(row.id)
            } label: {
                Text("×")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
            .frame(width: 24)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private func weightMenu(_ id: UUID) -> some View {
        Menu {
            ForEach(1...5, id: \.self) { n in
                Button("\(n)") { setHotwordWeight(id, n) }
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(hotwordRows.first { $0.id == id }?.weight ?? 1)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(width: 76, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line2, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func hotwordWordBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { hotwordRows.first { $0.id == id }?.word ?? "" },
            set: {
                if let index = hotwordRows.firstIndex(where: { $0.id == id }) {
                    hotwordRows[index].word = $0
                    persistHotwords()
                }
            })
    }

    private func setHotwordWeight(_ id: UUID, _ weight: Int) {
        if let index = hotwordRows.firstIndex(where: { $0.id == id }) {
            hotwordRows[index].weight = weight
            persistHotwords()
        }
    }

    private func addHotword() {
        hotwordRows.append(HotwordRow(word: "", weight: 1))
    }

    private func removeHotword(_ id: UUID) {
        hotwordRows.removeAll { $0.id == id }
        persistHotwords()
    }

    /// UI 行 → settings.asrVocabulary（空词行不落库；重名词后者覆盖；≤50 条）。
    private func persistHotwords() {
        var vocabulary: [String: Int] = [:]
        for row in hotwordRows {
            let word = row.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            vocabulary[word] = row.weight
        }
        environment.settings.asrVocabulary = vocabulary
    }

    private var dialectBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.keepDialect },
            set: { environment.settings.keepDialect = $0 })
    }

    /// 非热词/方言能力服务商的说明行（v2-glass caps 空时提示，逐字文案）。
    private var capsNoneNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Chip(text: "ℹ", tone: .neutral)
            Text("models.caps.none")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(4)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - 底部动作条（共享件；无温度门禁——本页无 MODEL PARAMETERS 卡）

    private var bottomBar: some View {
        ProviderDetailBottomBar(
            testDisabled: testState == .testing || !urlOK || !modelOK,
            saveDisabled: !urlOK || !modelOK,
            testState: testState,
            savedFlash: $savedFlash,
            saveKey: "models.save",
            savedKey: "models.saved",
            onTest: runTestConnection,
            onSave: save)
    }

    private var detailHint: String {
        String(format: String(localized: "models.detail.hint"), provider.displayName)
    }

    // MARK: - 载入 / 保存 / Keychain / 测试

    private func load() {
        // 「当前使用」chip 门槛与一级卡使用中一致：当前供应商且已配 Key（§41 追裁）
        // **且引擎走 API**（2026-10-11 互斥修复：本地模型使用中时 API 不显使用中）。
        let account = SecretAccount.asrAccount(for: provider)
        keyConfigured = ((try? environment.secrets.get(account)) ?? "")?.isEmpty == false
        isCurrent = environment.settings.asrProvider == provider
            && keyConfigured
            && environment.settings.asrMode == .api
        baseURLInput = environment.settings.asrBaseURL(for: provider)
        presetModel = environment.settings.asrModelPreset(for: provider)
        usesCustomModel = environment.settings.asrUsesCustomModel(for: provider)
        customModelInput = environment.settings.asrModelCustomID(for: provider)
        languageHints = environment.settings.languageHints
        hotwordRows = environment.settings.asrVocabulary
            .sorted { $0.key < $1.key }
            .map { HotwordRow(word: $0.key, weight: $0.value) }
        // Debug 起始态在镜像就绪后才放行（组件 onChange 响应）
        if keyDebugStart == .none { keyDebugStart = ProviderSettingsSupport.debugKeyStart }
    }

    /// 全字段落盘（本供应商分键）+ 成功闪「✓ 已保存」。
    /// Key 不在此列：三态字段全权接管其生命周期。语言/热词/方言即改即生效，也不在此列。
    /// 保存不切换当前听写服务（切换语义集中在一级卡「使用」按钮，LLM 同款裁决）。
    private func save() {
        guard urlOK, modelOK else { return }
        environment.settings.setASRBaseURL(
            baseURLInput.trimmingCharacters(in: .whitespaces), for: provider)
        // 生效模型 = 按分离规则算好写 asr.model.<provider>（live()/一级卡 chip 读它）；
        // 同时落三个 UI 状态键（preset/usesCustom/customID），下次进页回显一致。
        environment.settings.setASRModel(
            ProviderSettingsSupport.effectiveModel(
                hasPresets: !provider.modelPresets.isEmpty,
                preset: presetModel,
                usesCustom: usesCustomModel,
                customID: customModelInput),
            for: provider)
        environment.settings.setASRModelCustomID(
            customModelInput.trimmingCharacters(in: .whitespaces), for: provider)
        if !provider.modelPresets.isEmpty {
            environment.settings.setASRModelPreset(presetModel, for: provider)
            environment.settings.setASRUsesCustomModel(usesCustomModel, for: provider)
        }
        testState = .idle
        savedFlash = true
        savedFlashTask?.cancel()
        savedFlashTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { savedFlash = false }
        }
    }

    /// APIKeyField 提交（空=清除该账户 Key，非空=保存；掩码串已被状态机拦截不会到达）。
    /// 落盘走共享件（账户 = SecretAccount.asrAccount(for:)）；成功才刷新 chip 镜像。
    private func commitAPIKey(_ value: String) {
        if ProviderSettingsSupport.commitAPIKey(
            value,
            account: SecretAccount.asrAccount(for: provider),
            secrets: environment.secrets) {
            keyConfigured = !value.isEmpty
            // Key 增删即时联动「当前使用」chip（门槛 = 当前且已配 Key 且引擎走 API）
            isCurrent = environment.settings.asrProvider == provider
                && keyConfigured
                && environment.settings.asrMode == .api
            testState = .idle
        }
    }

    /// 测试连接（内置 MP3 探针）；先落当前合法输入，保证测的是所填配置。
    /// config 直接按本供应商表单组装（live() 读「当前供应商」——编辑非当前家时会
    /// 读错供应商，LLM 页同款警训）。
    private func runTestConnection() {
        guard testState != .testing, urlOK, modelOK else { return }
        save()
        testState = .testing

        let config = ASRConfig(
            provider: provider,
            baseURL: URL(string: baseURLInput.trimmingCharacters(in: .whitespaces))
                ?? URL(string: "https://maas.qianwenaiapi.com")!,
            apiKey: (try? environment.secrets.get(SecretAccount.asrAccount(for: provider))) ?? "",
            model: ProviderSettingsSupport.effectiveModel(
                hasPresets: !provider.modelPresets.isEmpty,
                preset: presetModel,
                usesCustom: usesCustomModel,
                customID: customModelInput),
            audioFormat: .mp3, // 探测负载为 MP3；契约 A 要求 MIME/format 与实际音频一致
            languageHints: environment.settings.languageHints,
            vocabulary: environment.settings.asrVocabulary,
            keepDialect: environment.settings.keepDialect)
        // 探针直走 API 引擎（同 use()：绕过模式路由，本地模式下也测目标供应商）
        let engine = environment.apiASREngine

        Task.detached {
            let outcome: TestState
            do {
                let probe = try TestProbeAudio.bundledURL()
                let result = try await engine.transcribe(audioFileAt: probe, config: config)
                AppLog.pipeline.info("asr test connection ok provider=\(config.provider.rawValue, privacy: .public) latency=\(result.latencyMs)ms")
                outcome = .success(String(format: String(localized: "settings.asr.test.success"), result.latencyMs))
            } catch let error as ASRError {
                // 兜底：若负载被判无语音（emptyResult）仍视为链路通（服务应答正常）
                if error == ASRError.emptyResult {
                    AppLog.pipeline.info("asr test connection ok (no words) provider=\(config.provider.rawValue, privacy: .public)")
                    outcome = .success(String(localized: "settings.asr.test.reached"))
                } else {
                    outcome = .failure(String(format: String(localized: "settings.asr.test.failed"), error.userMessage))
                }
            } catch {
                outcome = .failure(String(format: String(localized: "settings.asr.test.failed"), String(describing: error)))
            }
            await MainActor.run { testState = outcome }
        }
    }
}
