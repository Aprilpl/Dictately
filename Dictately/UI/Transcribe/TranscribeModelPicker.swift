import SwiftUI

/// 「转写模型」节（方案 D modelRow）：GlassSegmented API/本地 + 模型菜单（两组目录）
/// + 离线/云端提示。页面独立选择（不写回全局设置）——菜单 dim 规则：
/// API 供应商未配 Key →「未配置」；本地模型未下载 →「未下载」。
struct TranscribeModelPicker: View {
    @Environment(AppEnvironment.self) private var environment
    let controller: FileTranscribeController

    var body: some View {
        HStack(spacing: 10) {
            GlassSegmented(
                options: [AppSettings.ASRMode.api, .local],
                selection: Binding(
                    get: { controller.selection.mode },
                    set: { controller.setMode($0) }),
                small: true,
                label: { $0 == .api
                    ? String(localized: "transcribe.engine.api")
                    : String(localized: "transcribe.engine.local") })

            modelMenu

            Text(hintText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: 模型菜单

    private var modelMenu: some View {
        Menu {
            Section(String(localized: "transcribe.menu.group.api")) {
                ForEach(AppSettings.ASRProvider.allCases, id: \.self) { provider in
                    let configured = controller.isProviderConfigured(provider)
                    let selected = controller.selection.mode == .api
                        && controller.selection.apiProvider == provider
                    Button {
                        controller.setAPIProvider(provider)
                    } label: {
                        if selected {
                            Label(menuText(provider.displayName, suffix: configured ? nil : String(localized: "transcribe.menu.unconfigured")),
                                  systemImage: "checkmark")
                        } else {
                            Text(menuText(provider.displayName, suffix: configured ? nil : String(localized: "transcribe.menu.unconfigured")))
                        }
                    }
                    .disabled(!configured)
                }
            }
            Section(String(localized: "transcribe.menu.group.local")) {
                ForEach(LocalModelGroup.allCases) { group in
                    ForEach(LocalModelCatalog.models(in: group)) { model in
                        let installed = controller.isLocalModelAvailable(model.id)
                        let selected = controller.selection.mode == .local
                            && controller.selection.localRepoID == model.id
                        Button {
                            controller.setLocalModel(model.id)
                        } label: {
                            if selected {
                                Label(menuText(model.name, suffix: installed ? nil : String(localized: "transcribe.menu.notDownloaded")),
                                      systemImage: "checkmark")
                            } else {
                                Text(menuText(model.name, suffix: installed ? nil : String(localized: "transcribe.menu.notDownloaded")))
                            }
                        }
                        .disabled(!installed)
                    }
                }
            }
        } label: {
            triggerLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 菜单项文案：名称 + 可选状态后缀（未配置/未下载）。
    private func menuText(_ name: String, suffix: String?) -> String {
        suffix.map { "\(name) · \($0)" } ?? name
    }

    /// 触发钮：彩点（本地蓝 / API 绿）+ 当前选择名 + 下拉箭头（原型 .mbtn）。
    private var triggerLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLocal ? Theme.blue : Theme.ok)
                .frame(width: 7, height: 7)
            Text(currentName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5))
        .contentShape(Rectangle())
    }

    private var isLocal: Bool { controller.selection.mode == .local }

    /// 当前选择显示名（API = 供应商；本地 = 模型名；无效本地选择给占位）。
    private var currentName: String {
        if isLocal {
            guard let repoID = controller.selection.localRepoID,
                  let model = LocalModelCatalog.model(id: repoID) else {
                return String(localized: "transcribe.menu.pickModel")
            }
            return model.name
        }
        return controller.selection.apiProvider.displayName
    }

    /// 离线/云端提示（原型 modelhint 逐字）。
    private var hintText: String {
        isLocal
            ? String(localized: "transcribe.engine.hint.local")
            : String(localized: "transcribe.engine.hint.api")
    }
}
