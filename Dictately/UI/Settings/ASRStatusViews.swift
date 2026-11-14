import SwiftUI

struct EngineStatusBar: View {
    @Environment(AppEnvironment.self) private var environment

    let engineMode: AppSettings.ASRMode
    let activeLocalModelID: String?
    let currentProvider: AppSettings.ASRProvider
    let isLocalTab: Bool
    /// 当前供应商 Key 是否已配置（调用处传 keyStates 镜像，随 onAppear/二级页返回刷新）。
    let keyConfigured: Bool
    /// 「卸载」按钮回调（仅释放内存；引擎与 activeLocalModel 不动——用户裁决 2026-10-11）。
    var onUnload: () -> Void = {}

    private var localOn: Bool {
        guard let id = activeLocalModelID,
              LocalModelCatalog.model(id: id) != nil,
              environment.localModels.isInstalled(id) else { return false }
        return engineMode == .local
    }

    /// 本地引擎激活，或 API 引擎且当前供应商已配 Key；否则无可报告的引擎状态
    /// （含 engine=local 但活跃模型已删的残态——此前会错显绿色 API 分支）。
    private var showsEngineState: Bool {
        localOn || (engineMode == .api && keyConfigured)
    }

    var body: some View {
        if showsEngineState {
            bar
        }
    }

    private var bar: some View {
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
