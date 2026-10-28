#if DEBUG
import Foundation

/// 开发期 Key 旁路存储（TASK-048 层 C）：明文 JSON，权限 0600。
/// 双重门控——本类型整体 `#if DEBUG`（Release 二进制不含）+ 组装点以
/// `DICTATELY_DEV_SECRETS=1` 运行时开关选择。用途：裸跑 `.build` 二进制（无签名，
/// 必触发 Keychain 授权框）开发时零弹框。禁止用于 Release（AGENTS.md 硬约束 #2）。
final class FileSecretStore: SecretStore {
    struct StoreError: Swift.Error, CustomStringConvertible {
        let message: String
        var description: String { "FileSecretStore.Error: \(message)" }
    }

    private let fileURL: URL
    private let lock = NSLock()

    /// directory 参数化便于测试隔离；生产用 `~/Library/Application Support/Dictately/`。
    init(directory: URL? = nil) throws {
        let dir = directory ?? Self.defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("secrets.json")
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictately", isDirectory: true)
    }

    func set(_ value: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var dict = load()
        dict[account] = value
        try persist(dict)
    }

    func get(_ account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[account]
    }

    func delete(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var dict = load()
        dict.removeValue(forKey: account)
        try persist(dict)
    }

    // MARK: - 私有（整文件读写：仅两个条目，量级无意义）

    private func load() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func persist(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        // atomic 替换会以默认权限重建文件，写后立即收紧为 0600；
        // 收紧失败 = 安全属性未达成，删掉刚写的文件并报错（不留 0644 的 Key 文件）。
        try data.write(to: fileURL, options: .atomic)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw StoreError(message: "无法将 secrets.json 权限设为 0600：\(error)")
        }
    }
}
#endif
