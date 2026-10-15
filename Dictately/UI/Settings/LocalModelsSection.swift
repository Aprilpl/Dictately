import SwiftUI

/// 听写模型页 · 本地模型分支（TASK-134 原型落地；TASK-142 2026-10-13 按实测
/// 数据面原型 docs/design-demos/local-asr-models-bench.html 整体重构为两层式卡片：
/// 上层 = 名称 + 量化/徽标/使用中 chips + 简介，虚线分隔，下层 = 实测指标行
/// （中英星级/速度档/资源）+ 特性行 + 右侧 44pt 图标动作栏（Phosphor，
/// TASK-141）+ 横贯底部下载进度行；「✓ 使用中」挂标题行，使用中/下载中动作栏
/// 整体隐藏）。删除无二次确认（TASK-143 接管）；运行时横幅/分组头语义不变。
/// 「使用」语义不变：本地卡「使用」= asrMode=local + activeLocalModel，与 API
/// 互斥；引擎/活跃模型镜像经 Binding 上提（父层状态条同源刷新）。
struct LocalModelsSection: View {
    @Environment(AppEnvironment.self) private var environment

    /// 引擎镜像（本地「使用」时置 .local——父层状态条/一级卡互斥判定即时刷新）。
    let engineMode: Binding<AppSettings.ASRMode>
    /// 活跃本地模型镜像（父层持有；本地「使用」双写）。
    let activeModel: Binding<String?>
    /// 删除请求上提（TASK-143：父层持 pendingDelete 渲染二次确认模态）。
    let onRequestDelete: (LocalModelInfo) -> Void

    private var manager: ModelDownloadManager { environment.localModels }
    private var runtime: LocalRuntimeManager { environment.localRuntime }

    var body: some View {
        #if arch(x86_64)
        // mlx 运行时只有 Apple Silicon wheel（调研实锤）——Intel 机型本地分支只显说明
        unavailableNote(textKey: "models.local.intel.unavailable")
        #else
        VStack(alignment: .leading, spacing: 0) {
            runtimeBanner
            ForEach(Array(LocalModelGroup.allCases.enumerated()), id: \.element) { index, group in
                groupHeader(group, isFirst: index == 0)
                ForEach(LocalModelCatalog.models(in: group)) { model in
                    ModelCard(
                        model: model, engineMode: engineMode, activeModel: activeModel,
                        onRequestDelete: onRequestDelete)
                        .padding(.top, 10)
                }
            }
        }
        #endif
    }

    // MARK: - 运行时横幅（未就绪/安装中/失败；就绪不占位）

    @ViewBuilder
    private var runtimeBanner: some View {
        switch runtime.phase {
        case .ready:
            EmptyView()
        case .unavailable:
            unavailableNote(textKey: "models.local.runtime.missing")
        case .notInstalled:
            HStack(spacing: 12) {
                Text("models.local.runtime.needed")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
                    .lineSpacing(4)
                Spacer(minLength: 12)
                Button("models.local.runtime.install") {
                    runtime.install()
                }
                .buttonStyle(.themePrimary)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fillSoft))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.top, 10)
        case .installing(let step):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(stepText(step))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fillSoft))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.top, 10)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("models.local.runtime.failed")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.err)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(3)
                Button("models.local.runtime.retry") { runtime.install() }
                    .buttonStyle(.themeGhost)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fillSoft))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.top, 10)
        }
    }

    private func stepText(_ step: LocalRuntimeManager.Phase.InstallStep) -> String {
        switch step {
        case .creatingVenv: return String(localized: "models.local.runtime.step.venv")
        case .installingPackages: return String(localized: "models.local.runtime.step.pip")
        case .verifying: return String(localized: "models.local.runtime.step.verify")
        }
    }

    private func unavailableNote(textKey: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("ℹ")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text3)
            Text(textKey)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(5)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.fillSoft))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.top, 6)
    }

    // MARK: - 分组头（原型 .ghead：名称 + 说明 + 计数）

    private func groupHeader(_ group: LocalModelGroup, isFirst: Bool) -> some View {
        let models = LocalModelCatalog.models(in: group)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            // String 变量须显式包 LocalizedStringKey——直接 Text(string) 走 verbatim
            // 重载不查本地化表（深色目检实锤过 key 泄漏，勿改回）
            Text(LocalizedStringKey(group.nameKey))
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.text3)
            Text(LocalizedStringKey(group.noteKey))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .opacity(0.75)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(String(format: String(localized: "models.local.group.count"), models.count))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)
        }
        .padding(.top, isFirst ? 24 : 34)
        .padding(.bottom, 12)
    }
}

// MARK: - 模型卡（原型 .mcard 两层式）

private struct ModelCard: View {
    @Environment(AppEnvironment.self) private var environment

    let model: LocalModelInfo
    let engineMode: Binding<AppSettings.ASRMode>
    let activeModel: Binding<String?>
    let onRequestDelete: (LocalModelInfo) -> Void
    @State private var hovering = false
    /// 渠道菜单开关（下载图标 / 失败行「换渠道重试」两处宿主共享；NSPopover
    /// transient 外点/Esc 收起由系统承担，置 false 仅走「再点图标收起」路径）。
    @State private var showingChannelMenu = false

    private var settings: AppSettings { environment.settings }
    private var manager: ModelDownloadManager { environment.localModels }

    /// 渠道菜单内容：默认勾选 = 设置现值（每次弹出现读，无镜像过期问题——
    /// bug00013 的天然免疫形态）；选定 = 记住默认 + 立即按该渠道开下载。
    private var channelMenu: ChannelMenuView {
        ChannelMenuView(
            defaultChannel: settings.localDownloadChannel,
            remembered: settings.localDownloadChannelManual
        ) { channel in
            settings.localDownloadChannel = channel
            manager.startDownload(model, channel: channel)
            showingChannelMenu = false
        }
    }

    var body: some View {
        let isInstalled = manager.isInstalled(model.id)
        let isActive = settings.asrMode == .local && activeModel.wrappedValue == model.id && isInstalled
        let fraction = manager.downloadFractions[model.id]
        let isDownloading = fraction != nil
        let hasFailure = !isInstalled && manager.failureMessages[model.id] != nil

        VStack(alignment: .leading, spacing: 0) {
            // ── 上层：标题行（名 + 量化 chip + 徽标）+ 简介
            // （TASK-149：「✓ 使用中」标题行 chip 退役——使用中态由下层动作栏槽位
            // SlotSeal 图章承载，与两页供应商卡同语言）
            HStack(spacing: 8) {
                Text(model.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Chip(text: model.quant, tone: .neutral, font: Theme.mono(11), paddingH: 6, paddingV: 1.5)
                if let badge = model.badge {
                    Chip(
                        text: String(localized: String.LocalizationValue(badge.textKey)),
                        tone: badge.recommended ? .brand : .green,
                        paddingH: 7, paddingV: 2)
                }
            }
            Text(LocalizedStringKey(model.descKey))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            // ── 虚线分隔（.mlower border-top dashed，上 11 下 12）
            DashedDivider()
                .padding(.top, 11)

            // ── 下层：实测指标 + 特性（左） + 图标动作栏（右 44）。
            // 12pt 留白必须是容器级（原型 .mlower padding-top:12px）——放在文字块
            // 内部会被 center 对齐整块下推，动作栏（较高一侧）顶到分隔线（0 间距，
            // 用户实机指认的排版缺陷；修复后按钮 = 线下 12pt，文字在剩余空间居中）
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    metricsRow(model)
                    featuresRow(model).padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // .mact:empty{display:none}——下载中/失败整栏消失（失败行自带
                // 「换渠道重试」入口，双入口反而歧义——原型同语义）。使用中 =
                // 槽位 SlotSeal 图章占位（TASK-149：原「整栏消失」退役，与供应商卡
                // 「使用」钮变图章同一语言，槽位永驻不空）
                if !isDownloading && !hasFailure {
                    if isActive {
                        SlotSeal()
                            .frame(width: 44)
                    } else {
                        actionRail(model, isInstalled: isInstalled)
                    }
                }
            }
            .padding(.top, 12)

            // 下载进度 / 失败提醒横贯下层底部（.dlrow / .failrow 同位）
            if let fraction {
                downloadRow(model, fraction: fraction)
                    .padding(.top, 10)
            } else if hasFailure, let failure = manager.failureMessages[model.id] {
                failureRow(model, message: failure)
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 12).fill(isActive ? Theme.softBlueTintBg : Theme.fillSoft))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isActive ? Theme.softBlueTintBorder : (hovering ? Theme.line2 : Theme.line),
                    lineWidth: 1))
        .animation(.easeInOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .help(model.id)
        .padding(.top, 10)
        #if DEBUG
        .onAppear { debugAutoOpenChannelMenuIfNeeded() }
        #endif
    }

#if DEBUG
    /// Debug 自动化：`--channel-menu` 首个未安装卡自动弹渠道菜单（截图/走查用，
    /// 仅 Debug 编译；沿 --hotkey-capture 先例）。延迟 0.6s 等窗口/锚点布局。
    private func debugAutoOpenChannelMenuIfNeeded() {
        guard CommandLine.arguments.contains("--channel-menu"),
              !showingChannelMenu,
              let first = LocalModelCatalog.all.first(where: { !manager.isInstalled($0.id) }),
              first.id == model.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // 延迟闭包捕获结构体副本——经 onChange 语义重查当前态防陈旧
            guard !manager.isInstalled(model.id), !manager.isDownloading(model.id) else { return }
            showingChannelMenu = true
        }
    }
#endif

    // MARK: 指标行（原型 .mrow4：质量星级 · 速度档 + 耗时/分钟音频 · 资源）

    private func metricsRow(_ model: LocalModelInfo) -> some View {
        FlowHStack(itemSpacing: 30, lineSpacing: 8) {
            // 质量：中 ★★★★★ 英 ★★★★½
            HStack(spacing: 6) {
                Text("models.local.quality.zh")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                StarRating(value: model.qualityZH)
                Text("models.local.quality.en")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                StarRating(value: model.qualityEN)
            }
            // 速度：[档 chip] 中 1.9s · 英 2.7s / 分钟音频
            HStack(spacing: 6) {
                tierChip(model.speedTier)
                Text(
                    String(localized: "models.local.quality.zh") + " " + model.speedZH
                        + " · " + String(localized: "models.local.quality.en") + " " + model.speedEN
                )
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                Text("models.local.speed.permin")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            // 资源：[芯片] 0.6B 参数 内存 ≈0.8 GB · 磁盘 710 MB
            HStack(spacing: 6) {
                PhIcon(name: .cpu, size: 14)
                    .foregroundStyle(Theme.text3)
                    .help(Text("models.local.mem.stable"))
                resourceText(model)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    /// 速度档 chip（fast 快=绿 / mid 中=蓝 / slow·unstable=橙）。
    private func tierChip(_ tier: LocalModelSpeedTier) -> some View {
        Chip(
            text: String(localized: String.LocalizationValue(tier.labelKey)),
            tone: tier == .fast ? .green : (tier == .mid ? .brand : .orange),
            font: .system(size: 11, weight: .semibold),
            paddingH: 8, paddingV: 1.5)
    }

    /// 资源串：`参数 0.6B 内存≈0.8 GB 磁盘≈710 MB`（2026-10-14 用户裁决：
    /// 标签前置、≈ 紧贴数值、全行无加粗——参数量 semibold 与「0.6B 参数」序退役）。
    private func resourceText(_ model: LocalModelInfo) -> Text {
        var line = Text(String(localized: "models.local.meta.params"))
        if let params = model.params {
            line = line + Text(" " + params)
        }
        if let mem = model.memHint {
            line = line
                + Text(" ")
                + Text(String(format: String(localized: "models.local.meta.mem"), mem))
        }
        return (line
            + Text(" ")
            + Text(String(format: String(localized: "models.local.meta.disk"), LocalModelCatalog.sizeText(model.sizeBytes)))
        ).foregroundStyle(Theme.text2)
    }

    // MARK: 特性行（语言/方言 dim chips 在前 + 特性绿/橙 chips）

    private func featuresRow(_ model: LocalModelInfo) -> some View {
        FlowHStack(itemSpacing: 6, lineSpacing: 6) {
            ForEach(model.langChipKeys, id: \.self) { key in
                Chip(
                    text: String(localized: String.LocalizationValue(key)),
                    tone: .dim,
                    font: .system(size: 11, weight: .medium),
                    paddingH: 8, paddingV: 1.5)
            }
            ForEach(Array(model.features.enumerated()), id: \.offset) { _, feature in
                Chip(
                    text: String(localized: String.LocalizationValue(feature.textKey)),
                    tone: feature.isGood ? .green : .orange,
                    font: .system(size: 11, weight: .medium),
                    paddingH: 8, paddingV: 1.5)
            }
        }
    }

    // MARK: 动作栏（原型 .mact 44pt：34×34 图标钮纵排）

    private func actionRail(_ model: LocalModelInfo, isInstalled: Bool) -> some View {
        VStack(spacing: 6) {
            if isInstalled {
                RailButton(icon: .arrowCircleRight, kind: .gray, helpText: String(localized: "models.use.help")) {
                    use(model)
                }
                RailButton(icon: .trashSimple, kind: .ghostDanger, helpText: String(localized: "models.local.delete.help")) {
                    // TASK-143：请求上提，父层弹二次确认模态（双保险：使用中卡片
                    // 无删除入口 + deleteInstalled 内部守卫）
                    onRequestDelete(model)
                }
            } else {
                // TASK-144：点下载图标先弹渠道菜单（图标本体零改动——只换行为）；
                // 「下载时现选」+ 选定记住默认，原型 download-channel-menu.html 定稿
                ChannelMenuHost(isPresented: $showingChannelMenu, menu: channelMenu) {
                    RailButton(
                        icon: .downloadSimple, kind: .gray,
                        helpText: String(format: String(localized: "models.local.download.help"), LocalModelCatalog.sizeText(model.sizeBytes))
                    ) {
                        showingChannelMenu.toggle()
                    }
                }
            }
        }
        .frame(width: 44)
    }

    // MARK: 下载进度行（.dlrow：进度条 flex1 + 正在下载 N% + 取消）

    private func downloadRow(_ model: LocalModelInfo, fraction: Double) -> some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.field)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Theme.blue, Color(red: 0x5a / 255, green: 0xc8 / 255, blue: 0xfa / 255)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: 5)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line, lineWidth: 1))
            // 渠道名段先行内定样式再拼接（Text 修饰符作用于拼接前段，整段统管字号）
            (Text("\(String(localized: "models.local.downloading")) \(Int((fraction * 100).rounded()))%")
                + Text(" · \(channelMark)").fontWeight(.semibold).foregroundStyle(Theme.text2))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            CancelTextButton(title: String(localized: "models.local.cancel")) {
                manager.cancelDownload(model.id)
            }
        }
    }

    /// 进度行渠道名（原型 .chanmark：t2 semibold；渠道缺失 = 空串不显）。
    private var channelMark: String {
        manager.downloadChannels[model.id]?.displayName ?? ""
    }

    // MARK: 失败提醒行（原型 .failrow：占下载进度行同位——不自动换渠道，
    // 红字提醒 + 渠道与重试说明 + 「换渠道重试」再弹渠道菜单）

    private func failureRow(_ model: LocalModelInfo, message: String) -> some View {
        let channelName = manager.downloadChannels[model.id]?.displayName ?? ""
        return HStack(spacing: 10) {
            Text(String(format: String(localized: "models.local.fail.title"), message))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.err)
                .lineLimit(1)
            Text(String(format: String(localized: "models.local.fail.sub"), channelName))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            Spacer(minLength: 12)
            ChannelMenuHost(isPresented: $showingChannelMenu, menu: channelMenu) {
                Button("models.local.fail.retry") {
                    showingChannelMenu.toggle()
                }
                .buttonStyle(.themeGhost)
                .controlSize(.small)
            }
        }
    }

    // MARK: 动作

    private func use(_ model: LocalModelInfo) {
        settings.activeLocalModel = model.id
        settings.asrMode = .local
        // 镜像上提（Binding 双写）：父层状态条/一级卡互斥判定即时刷新
        activeModel.wrappedValue = model.id
        engineMode.wrappedValue = .local
    }
}

// MARK: - 卡片原子件
// （RailButton / SlotSeal / KeyBadge / DashedDivider 均在 UI/Support/RailButton.swift
// 共享——TASK-146 抽出 RailButton，TASK-149 增槽位图章/钥匙徽并迁 DashedDivider；
// 三处卡片（本文件 + 两页供应商卡）共用同 target 共享件。InUseChip 已随 TASK-149 退役。）

/// 星级（原型 .stars）：底 5 灰星 + 顶金星按 value/5 比例水平裁切（半星 = 50%）。
/// 注：ZStack+GeometryReader 与 overlay+mask 两种构造实测报告宽度一致
/// （NSHostingView harness 验证 67pt/67pt），组件本身不吞间距——曾误判其为
/// 间距不均根因后改写又还原，留注防再查（真凶见 placeSubviews 间距时序）。
private struct StarRating: View {
    let value: Double

    private var stars: some View {
        Text("★★★★★")
            .font(.system(size: 11.5))
            .tracking(1.5)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            stars.foregroundStyle(Theme.line2)
            GeometryReader { proxy in
                stars.foregroundStyle(Theme.star)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: proxy.size.width * value / 5)
                    }
            }
        }
        .fixedSize()
        .help(String(format: "%.1f / 5", value))
    }
}

/// 流式换行容器（原型 flex-wrap 对应；metrics 行列距 30/行距 8、chips 6/6）。
private struct FlowHStack: Layout {
    var itemSpacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, contentWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + itemSpacing + size.width > maxWidth + 0.5 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += (x > 0 ? itemSpacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, x)
        }
        return CGSize(width: contentWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 两遍式：先按换行规则分出行并算出每行最终行高，再统一放置——行内全部
        // 元素按「最终行高」居中，共享一条真实中线。单遍放置（用放置时的累积行高）
        // 会让首个元素顶到 -(h/2)、先矮后高的行永远回正——指标行星级/资源错位、
        // 特性行首枚 chip 骑高的根因（用户截图指认，2026-10-14）
        var rows: [[Int]] = [[]]
        var rowHeights: [CGFloat] = [0]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + itemSpacing + size.width > bounds.width + 0.5 {
                rows.append([])
                rowHeights.append(0)
                x = 0
            }
            rows[rows.count - 1].append(index)
            rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            x += (x > 0 ? itemSpacing : 0) + size.width
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--flow-debug") {
            let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
            var placements = ""
            var dbgY: CGFloat = 0
            for (rowIndex, row) in rows.enumerated() {
                var dbgX: CGFloat = 0
                for (position, index) in row.enumerated() {
                    if position > 0 { dbgX += itemSpacing }
                    placements += String(format: "[%d] x=%.1f y=%.1f w=%.1f  ", index, bounds.minX + dbgX, bounds.minY + dbgY, subviews[index].sizeThatFits(.unspecified).width)
                    dbgX += widths[index]
                }
                dbgY += rowHeights[rowIndex] + lineSpacing
            }
            print("FLOW boundsW=\(bounds.width) items=\(widths.map { String(format: "%.1f", $0) }.joined(separator: ","))")
            print("FLOW place: \(placements)")
        }
        #endif
        var y: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            let height = rowHeights[rowIndex]
            var rowX: CGFloat = 0
            for (position, index) in row.enumerated() {
                // 间距在放置前、且仅对非行首元素累加——此前「放置后自增 + rowX>0 判定」
                // 在放完首项时 rowX 仍为 0，首对相邻元素永远漏加 itemSpacing
                // （指标行 A≈0/B≈30 不均的真正根因，埋点实测 x=0/173/396 定位）
                if position > 0 { rowX += itemSpacing }
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + rowX, y: bounds.minY + y + (height - size.height) / 2),
                    proposal: .unspecified)
                rowX += size.width
            }
            y += height + lineSpacing
        }
    }
}

/// 下载取消文字钮（原型 .dl-x：11.5 t3，hover 变红，无边框）。
private struct CancelTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(hovering ? Theme.err : Theme.text3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - 渠道选择菜单（TASK-144 · 原型 download-channel-menu.html 定稿）

/// 渠道菜单宿主：包住任意触发视图，isPresented 置真时在其下缘弹出渠道菜单。
/// NSPopover transient（沿 APIKeyField 确认气泡先例：外点/Esc 收起由系统承担；
/// 先 loadViewIfNeeded+layoutSubtreeIfNeeded 拿 fittingSize 再 show，防零尺寸
/// 翻转定位；preferredEdge .maxY = 贴锚点下方——macOS 15 实测定稿语义）。
private struct ChannelMenuHost<Anchor: View>: View {
    @Binding var isPresented: Bool
    let menu: ChannelMenuView
    @ViewBuilder let anchor: Anchor

    var body: some View {
        anchor.background(
            ChannelMenuAnchorRepresentable(isPresented: $isPresented, menu: menu))
    }
}

/// 锚点 + 气泡生命周期载体（View 非 NSObject，delegate 落 Coordinator）。
private struct ChannelMenuAnchorRepresentable: NSViewRepresentable {
    @Binding var isPresented: Bool
    let menu: ChannelMenuView

    func makeNSView(context: Context) -> NSView { context.coordinator.anchorView }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        if isPresented, coordinator.popover == nil {
            coordinator.present(from: view, menu: menu) {
                // 系统收口（外点/Esc/选完由 popover.close 走 delegate）同步置假，
                // 触发器选中态与实际显示保持一致
                if isPresented { isPresented = false }
            }
        } else if !isPresented, let popover = coordinator.popover {
            // 程序化关闭路径（再点图标收起）：close 触发 popoverDidClose，
            // onSystemClose 里的置假已是同值（幂等）
            popover.close()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSPopoverDelegate {
        let anchorView = NSView()
        var popover: NSPopover?
        var onSystemClose: (() -> Void)?

        func present(from anchor: NSView, menu: ChannelMenuView, attempt: Int = 0,
                     onSystemClose: @escaping () -> Void) {
            // 锚点未挂窗或首帧 bounds 未布局（zero rect 会让 popover 定位翻转到
            // 锚点上方）：短暂重试，isPresented 已翻假即止（沿 APIKeyField 同款）
            guard anchor.window != nil,
                  anchor.frame.width > 1, anchor.frame.height > 1 else {
                guard attempt < 25 else { onSystemClose(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.present(from: anchor, menu: menu, attempt: attempt + 1,
                                  onSystemClose: onSystemClose)
                }
                return
            }
            let popover = NSPopover()
            popover.behavior = .transient
            let hosting = NSHostingController(rootView: menu)
            popover.contentViewController = hosting
            hosting.loadViewIfNeeded()
            hosting.view.layoutSubtreeIfNeeded()
            popover.contentSize = hosting.view.fittingSize
            self.onSystemClose = onSystemClose
            popover.delegate = self
            self.popover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            onSystemClose?()
            onSystemClose = nil
        }
    }
}

/// 渠道菜单内容（原型 .dl-pop：272pt 卡 = 标题 + 两渠道行 + 脚注；
/// 默认渠道勾选圈 + 「默认」chip，脚注按「按地区自动/已记住」二态）。
private struct ChannelMenuView: View {
    let defaultChannel: AppSettings.DownloadChannel
    let remembered: Bool
    let onPick: (AppSettings.DownloadChannel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("models.local.channel.title")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 11)
                .padding(.bottom, 7)
            channelRow(.modelScope)
            channelRow(.huggingFace)
            Rectangle()
                .fill(Theme.line)
                .frame(height: 0.5)
                .padding(.top, 8)
            Text(remembered ? "models.local.channel.foot.remembered"
                            : "models.local.channel.foot.auto")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.top, 7)
                .padding(.bottom, 3)
        }
        .frame(width: 272)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.modalBg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line2, lineWidth: 1))
    }

    /// 渠道行：勾选圈 16 + 名称/host + 默认 chip（原型 .chan）。
    private func channelRow(_ channel: AppSettings.DownloadChannel) -> some View {
        ChannelRow(
            channel: channel,
            isDefault: channel == defaultChannel,
            onPick: { onPick(channel) })
    }
}

/// 单条渠道行（hover 换 fillSoft 底；独立小视图隔离 hover 态）。
private struct ChannelRow: View {
    let channel: AppSettings.DownloadChannel
    let isDefault: Bool
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(isDefault ? Theme.blue : Theme.line2, lineWidth: 1.5)
                    if isDefault {
                        Circle().fill(Theme.blue)
                        Text("✓")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    Text(channel.hostName)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isDefault {
                    Chip(
                        text: String(localized: "models.local.channel.default"),
                        tone: .neutral,
                        font: .system(size: 12, weight: .medium),
                        paddingH: 7, paddingV: 2)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Theme.fillSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
