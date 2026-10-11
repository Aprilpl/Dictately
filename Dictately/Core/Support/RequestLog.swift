import Foundation

/// ASR/LLM 外发请求日志（JSONL 落盘到数据目录，2026-10-10 用户裁决）。
///
/// 一行一请求（`request-log.jsonl`），覆盖三条请求路径的全部出口（正式听写/润色/
/// 重新生成 + 设置页测试连接探测）：
/// - `kind` = asr-qwen / asr-openai-compatible / llm；`purpose` = transcribe / polish / test
/// - 请求参数全文落盘（messages 含口述文本、Prompt 模板），音频只记元数据
///   `{mime, bytes}`——base64 一条 1–2MB，落盘即日志爆炸（用户裁决）
/// - **API Key 恒脱敏**（`Bearer <redacted>(len=N)`，保留长度供残值 Key 排查）
///   ——Key 是用户财产，明文绝不落盘（Keychain 保护基线，硬约束 #6）
/// - 成功响应只记 status/latencyMs；失败附 bodySummary 前 200 字符（与 os_log 摘要同口径）
/// - 本地拦截（空 Key / 非法 URL / 文件读取失败）同样记一条（status=nil + error），
///   「为什么没发出去」与「发了什么」在同一份日志里可查
///
/// 线程与健壮性：内部串行队列串行化写入；写失败仅走 os_log error，绝不影响请求
/// 路径（日志是观测，不是链路依赖）。开关 `enabled` 闭包每次写入现读（设置页
/// 切换即时生效，沿 SoundFeedback.isEnabled 先例）。轮转：超过 maxBytes 时当前文件
/// 改名为 `request-log.1.jsonl`（覆盖上一份）后新建。
final class RequestLog {
    /// 一条请求记录。ts 在构造时刻（≈请求发起）打点；status/latencyMs/error/
    /// bodySummary 由客户端在各退出分支补齐。
    struct Entry {
        enum Kind: String {
            case asrQwen = "asr-qwen"
            case asrCompatible = "asr-openai-compatible"
            case llm = "llm"
        }
        enum Purpose: String {
            case transcribe
            case polish
            case test
        }

        let ts: String
        let kind: Kind
        let purpose: Purpose
        let method: String
        let url: String
        /// 落盘形态的请求头（Authorization 已是脱敏串，勿在此放明文 Key）。
        let headers: [String: String]
        /// 请求参数（音频只记 {mime, bytes} 元数据；LLM 为完整请求体 JSON 对象）。
        let request: [String: Any]
        var status: Int?
        var latencyMs: Int?
        var error: String?
        /// 失败响应的 body 摘要（前 200 字符，与 os_log 4xx/5xx 日志同口径）。
        var bodySummary: String?

        init(
            kind: Kind,
            purpose: Purpose,
            url: String,
            headers: [String: String],
            request: [String: Any],
            error: String? = nil
        ) {
            self.ts = Self.timestampFormatter.string(from: Date())
            self.kind = kind
            self.purpose = purpose
            self.method = "POST"
            self.url = url
            self.headers = headers
            self.request = request
            self.error = error
        }

        /// 本地拦截路径（请求未发出）的便捷构造。
        static func rejected(
            kind: Kind,
            purpose: Purpose,
            url: String,
            request: [String: Any] = [:],
            error: String
        ) -> Entry {
            Entry(kind: kind, purpose: purpose, url: url, headers: [:], request: request, error: error)
        }

        var jsonObject: [String: Any] {
            [
                "ts": ts,
                "kind": kind.rawValue,
                "purpose": purpose.rawValue,
                "method": method,
                "url": url,
                "headers": headers,
                "request": request,
                "response": [
                    "status": status ?? NSNull(),
                    "latencyMs": latencyMs ?? NSNull(),
                    "error": error ?? NSNull(),
                    "bodySummary": bodySummary ?? NSNull(),
                ] as [String: Any],
            ]
        }

        static let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }

    /// 默认文件：数据目录 `~/Library/Application Support/Dictately/request-log.jsonl`
    /// （与 sqlite/Recordings/secrets.json 同目录；设置页「打开数据文件夹」一键可达。
    /// 勿放 .app 安装目录——写入会破坏 codesign 签名且 /Applications 非保证可写）。
    static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Dictately", isDirectory: true)
            .appendingPathComponent("request-log.jsonl", isDirectory: false)
    }

    /// Authorization 头脱敏：保留 Key 长度（§24 残值 Key 案：8 字符录入残值靠长度现形），
    /// 明文绝不落盘。
    static func redactedAuthorization(apiKey: String) -> String {
        "Bearer <redacted>(len=\(apiKey.count))"
    }

    /// 落盘形态的完整请求头集合（authorization 传脱敏串；extra 为端点附加头，
    /// 如 OpenCode 的 x-opencode-session）。
    static func loggedHeaders(
        authorization: String,
        contentType: String,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var headers = ["Content-Type": contentType, "Authorization": authorization]
        for (name, value) in extra { headers[name] = value }
        return headers
    }

    private let fileURL: URL
    private let maxBytes: Int
    private let enabled: () -> Bool
    private let queue = DispatchQueue(label: "com.dictately.request-log")

    /// - Parameters:
    ///   - enabled: 每次写入现读（即时生效）；默认恒开（生产装配传入 settings 闭包）。
    ///   - maxBytes: 轮转阈值，超过即把当前文件改名 `*.1.jsonl` 后新建。
    init(
        fileURL: URL = RequestLog.defaultFileURL(),
        maxBytes: Int = 5 * 1024 * 1024,
        enabled: @escaping () -> Bool = { true }
    ) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.enabled = enabled
    }

    /// 追加一条记录（fire-and-forget：序列化在调用线程，写盘在内部串行队列；
    /// 任何失败静默降级为 os_log，不影响请求路径）。
    func append(_ entry: Entry) {
        guard enabled() else { return }
        // 数字形态与网线同源（§49）：JSONSerialization 会把 0.7 打成 17 位有效数字
        // （0.69999999999999996），而实发请求体（JSONEncoder）是最短往返形态 "0.7"
        // ——日志行同样经 JSONEncoder 编码，数字文本与实发字节一致。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let root = LogValue(entry.jsonObject),
              let line = try? encoder.encode(root)
        else {
            AppLog.pipeline.error("request-log: entry not serializable (kind=\(entry.kind.rawValue, privacy: .public))")
            return
        }
        let url = fileURL
        let limit = maxBytes
        queue.async { [weak self] in
            self?.write(line, to: url, rotatingOver: limit)
        }
    }

    /// 等待在途写入全部落盘（串行队列屏障）。测试钩子，生产代码勿调。
    func flush() {
        queue.sync {}
    }

    // MARK: - 写盘（串行队列内）

    private func write(_ line: Data, to url: URL, rotatingOver limit: Int) {
        let fm = FileManager.default
        do {
            let dir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            // 轮转：写前查体积；改名原子，覆盖上一份轮转文件
            if let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int), size > 0,
               size + line.count > limit {
                let rotated = Self.rotatedURL(for: url)
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data([0x0A])) // JSONL 换行
        } catch {
            AppLog.pipeline.error("request-log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `request-log.jsonl` → `request-log.1.jsonl`（任意扩展名通用）。
    private static func rotatedURL(for url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(base).1" : "\(base).1.\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }
}

// MARK: - [String: Any] → Encodable 盒装

/// `Entry.jsonObject` 是 `[String: Any]`，JSONEncoder 不直接吃——经此枚举递归盒装。
/// 关键在数字分型：Bool/Int/Double 必须各自成 case（Any 里的 NSNumber 靠 CF 类型
/// 分辨布尔与浮点），Double 走 encode(Double) 才得到最短往返文本（0.7 → "0.7"）。
private enum LogValue: Encodable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case null
    case array([LogValue])
    case object([String: LogValue])

    init?(_ any: Any) {
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        } else if let string = any as? String {
            self = .string(string)
        } else if any is NSNull {
            self = .null
        } else if let dict = any as? [String: Any] {
            var boxed: [String: LogValue] = [:]
            for (key, value) in dict {
                guard let item = LogValue(value) else { return nil }
                boxed[key] = item
            }
            self = .object(boxed)
        } else if let array = any as? [Any] {
            var boxed: [LogValue] = []
            for value in array {
                guard let item = LogValue(value) else { return nil }
                boxed.append(item)
            }
            self = .array(boxed)
        } else {
            return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}
