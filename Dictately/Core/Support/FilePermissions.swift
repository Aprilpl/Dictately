import Foundation

/// 用户数据目录权限收紧（TASK-181，§86 低危清单）：
/// `Application Support/Dictately` 及其子目录（Recordings/Models/Runtime/venv）默认
/// 按 umask 常见 0755 创建——其他本机用户可读历史、模型与运行时。统一收紧为
/// 目录 0700 / 文件 0600；失败只记日志不阻断（与 request-log 语义一致：数据是用户
/// 资产，不因权限收不去而删除）。
enum FilePermissions {
    static let ownerOnlyDirectory = 0o700
    static let ownerOnlyFile = 0o600

    /// 目录不存在则创建，存在则幂等收紧为 0700（含父目录创建）。
    static func ensureOwnerOnlyDirectory(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: ownerOnlyDirectory])
            } catch {
                AppLog.app.error(
                    "data dir create failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        do {
            try fm.setAttributes(
                [.posixPermissions: ownerOnlyDirectory], ofItemAtPath: url.path)
        } catch {
            AppLog.app.error(
                "data dir chmod failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 已存在的文件收紧为 0600（数据库/密钥类）；不存在时静默跳过。
    static func ensureOwnerOnlyFile(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.setAttributes([.posixPermissions: ownerOnlyFile], ofItemAtPath: url.path)
        } catch {
            AppLog.app.error(
                "data file chmod failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
