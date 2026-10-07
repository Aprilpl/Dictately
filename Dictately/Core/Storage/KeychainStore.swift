import Foundation
import Security

/// API Key 的 Keychain 存取（PRD §3：kSecClassGenericPassword，service="Dictately"，account 参数化）。
/// 错误不吞：真实 OSStatus 抛 `KeychainStoreError`；「条目不存在」不是错误——get 返回 nil、delete 视为无操作。
/// 安全约束（PRD §7）：错误与日志中禁止出现 Key 明文——本类型的错误只携带 OSStatus 与描述，不含值。
///
/// 开发注（TASK-048，2026-09-30 裁决）：Keychain ACL 按代码签名绑定，重构建签名变化触发
/// 系统「登录钥匙串」授权框（Security Agent UI，App 接触不到所输密码）。缓解三层：
/// 旧签名条目一次性清理+稳定身份重存（见 docs/dev-notes/keychain-migration.md）、
/// CachingSecretStore 每账户每进程至多一次底层读、Debug 裸跑走 FileSecretStore 旁路。
final class KeychainStore: SecretStore {
    /// Keychain 操作错误。`status` 为底层 OSStatus；`message` 来自 SecCopyErrorMessageString（系统文案，不含敏感值）。
    struct Error: Swift.Error, CustomStringConvertible {
        let status: OSStatus
        let message: String
        var description: String { "KeychainStore.Error(\(status)): \(message)" }
    }

    /// PRD §3 定义的 Key 键（兼容别名——常量上移 `SecretAccount`，供非 Keychain 后端共用）。
    typealias Account = SecretAccount

    private let service: String

    /// service 参数化便于测试隔离；生产用默认 "Dictately"。
    init(service: String = "Dictately") {
        self.service = service
    }

    // MARK: - 三操作：set / get / delete

    /// 写入（已存在则覆盖——先删后加，规避 errSecDuplicateItem）。
    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(for: account)
        SecItemDelete(query as CFDictionary) // 覆盖旧值；不存在时忽略返回值
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error(status: status, message: Self.message(for: status)) }
    }

    /// 读取；条目不存在返回 nil（非错误）。
    func get(_ account: String) throws -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw Error(status: errSecDecode, message: "存储的值不是合法 UTF-8 字符串")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw Error(status: status, message: Self.message(for: status))
        }
    }

    /// 删除；条目不存在视为成功（无操作，不抛）。
    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error(status: status, message: Self.message(for: status))
        }
    }

    // MARK: - 私有

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func message(for status: OSStatus) -> String {
        if let cf = SecCopyErrorMessageString(status, nil) {
            return cf as String
        }
        return "未知 Keychain 错误"
    }
}
