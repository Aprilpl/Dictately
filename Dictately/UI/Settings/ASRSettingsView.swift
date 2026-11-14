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
                // 本地引擎亮蓝高亮，右端内存监控仅本地 Tab 显示；
                // TASK-165：未配置态（engine=api 且当前供应商无 Key、本地未激活）整条隐藏）
                EngineStatusBar(
                    engineMode: engineMode,
                    activeLocalModelID: activeLocalModelID,
                    currentProvider: currentProvider,
                    isLocalTab: displayedMode == .local,
                    keyConfigured: keyStates[currentProvider] ?? false,
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
        PageHeader(titleKey: "models.title", descKey: "models.desc")
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
/// 显示门槛（TASK-165）：本地引擎激活，或 API 引擎且当前供应商已配 Key——
/// 新装零配置态整条隐藏，不出现绿色「API · 默认模型」的假在线提示。
