import SwiftUI

/// 本地模型删除二次确认 · 居中模态（TASK-143，2026-10-13 用户裁决；
/// 原型 docs/design-demos/local-model-delete-confirm.html 形态 A 逐项落地）：
/// 窗口级遮罩（Theme.maskScrim 平色非毛玻璃，点击/Esc 取消）+ 352pt 玻璃卡
/// （红色垃圾桶图标 + 「删除 <模型名>？」+ 释放空间说明 + 取消/删除；Esc 提示
/// 文字 2026-10-25 随「移除关闭指引类文案」追裁删除，三路收口行为不变）。
/// 入场 0.18s opacity+scale(.96)（原型 mask-in/modal-in）。确认/取消均由父层
/// 收口（父层持 pendingDelete 状态与删除动作）。
struct LocalModelDeleteConfirm: View {
    let model: LocalModelInfo
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Theme.maskScrim)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            card
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                PhIcon(name: .trash, weight: .bold, size: 15)
                    .foregroundStyle(Theme.err)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.redTintBg))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.redTintBorder, lineWidth: 1))
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(format: String(localized: "models.local.delete.confirm.title"), model.name))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text1)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    bodyText
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(4.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 10)
                Button("models.local.delete.confirm.cancel") { onCancel() }
                    .buttonStyle(.themeGhost)
                Button("models.local.delete.confirm.delete") { onConfirm() }
                    .buttonStyle(.themeDanger)
            }
            .padding(.top, 18)
        }
        .padding(.top, 20)
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(width: 352, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.modalBg)
                .shadow(color: .black.opacity(0.36), radius: 45, x: 0, y: 30)
                .shadow(color: .black.opacity(0.16), radius: 9, x: 0, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line2, lineWidth: 1))
        .contentShape(Rectangle())
        // 吞卡内点击——防冒泡到遮罩误取消（原型 stopPropagation 对应）
        .onTapGesture {}
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    /// 说明正文：`将删除已下载的模型文件，释放约 **X** 磁盘空间。删除后可随时重新下载。`
    /// （体积段 mono 11.5 semibold text1，原型 .m 对应）
    private var bodyText: Text {
        Text(String(localized: "models.local.delete.confirm.body.pre"))
            + Text(LocalModelCatalog.sizeText(model.sizeBytes))
                .font(Theme.mono(11.5))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.text1)
            + Text(String(localized: "models.local.delete.confirm.body.post"))
    }
}
