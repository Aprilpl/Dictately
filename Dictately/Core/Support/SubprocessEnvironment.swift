import Foundation

/// 子进程环境最小化（TASK-180，§86 低危清单）：
/// Python sidecar / pip 不需要宿主全量环境；透传 `PYTHONPATH`、`PIP_CONFIG_FILE`、
/// `DYLD_INSERT_LIBRARIES` 等只会扩大污染与注入面。白名单只保留运行必需项
/// （PATH/HOME/TMPDIR/语言）与代理变量（企业/校园网用户依赖，且不影响代码执行面）。
enum SubprocessEnvironment {
    static let allowedKeys: Set<String> = [
        "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME",
        // 代理（大小写两套环境变量都常见）
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    ]

    /// 过滤宿主环境：未列入白名单的键一律丢弃（调用方仍可显式追加自己的变量）。
    static func minimal(from environment: [String: String]) -> [String: String] {
        environment.filter { allowedKeys.contains($0.key) }
    }
}
