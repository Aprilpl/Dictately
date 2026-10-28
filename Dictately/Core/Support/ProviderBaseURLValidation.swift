import Foundation

/// 两供应商目录（LLM / ASR）共用的 Base URL 合法性判定（§85 收敛——此前两份逐字节相同）。
/// 需合法 URL 且含主机名；custom 放行 http（本地自建网关），其余 https-only。
protocol ProviderBaseURLValidating {
    var allowsPlainHTTP: Bool { get }
}

extension ProviderBaseURLValidating {
    /// 设置页保存/测试连接同一判定入口。
    func baseURLIsValid(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              url.host != nil else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return allowsPlainHTTP
        default: return false
        }
    }
}
