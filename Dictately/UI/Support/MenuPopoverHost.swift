import AppKit
import SwiftUI

/// 菜单气泡宿主（共享件；TASK-153 自 LocalModelsSection.ChannelMenuHost 泛化抽取，
/// 行为零改动）：包住任意触发视图，isPresented 置真时在其下缘弹出任意内容的
/// transient NSPopover。现用方：本地模型渠道菜单、快捷键页触发键菜单（TriggerKeyMenu）。
///
/// 沿 APIKeyField 确认气泡先例：外点/Esc 收起由系统承担；先 loadViewIfNeeded +
/// layoutSubtreeIfNeeded 拿 fittingSize 再 show，防零尺寸翻转定位；
/// preferredEdge .maxY = 贴锚点下方（macOS 15 实测定稿语义）。
/// 内容在弹出瞬间取值（popover 存续期不随状态重建）——菜单都是「开即快照」用法。
struct MenuPopoverHost<Anchor: View, Content: View>: View {
    @Binding var isPresented: Bool
    let menu: Content
    @ViewBuilder let anchor: Anchor

    var body: some View {
        anchor.background(
            MenuPopoverAnchorRepresentable(isPresented: $isPresented, menu: menu))
    }
}

/// 锚点 + 气泡生命周期载体（View 非 NSObject，delegate 落 Coordinator）。
private struct MenuPopoverAnchorRepresentable<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let menu: Content

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
            // 程序化关闭路径（再点触发钮收起）：close 触发 popoverDidClose，
            // onSystemClose 里的置假已是同值（幂等）
            popover.close()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSPopoverDelegate {
        let anchorView = NSView()
        var popover: NSPopover?
        var onSystemClose: (() -> Void)?

        func present(from anchor: NSView, menu: Content, attempt: Int = 0,
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
