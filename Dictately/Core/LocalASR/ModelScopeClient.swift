import Foundation

/// 仓库文件树条目（渠道中立值类型：ModelScope / HuggingFace 客户端各自解码为它；
/// TASK-144 渠道化时由 ModelScopeFile 更名）。sha256 = 仓库侧校验和（小写 hex，
/// 下载完成比对；渠道无值时为 nil → 校验自然跳过）。
struct ModelRepoFile: Equatable {
    /// 仓库内相对路径（如 "model.safetensors"、"tokenizer/config.json"）。
    let path: String
    /// 字节数。
    let size: Int64
    /// 仓库侧校验和（小写 hex；下载完成比对）。
    let sha256: String?
    let isLFS: Bool

    init(path: String, size: Int64, sha256: String? = nil, isLFS: Bool = false) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.isLFS = isLFS
    }
}

/// ModelScope（国内站）匿名直链客户端（TASK-134 调研结论：公开仓库无需
/// token/Cookie/UA；TASK-144 起为双渠道之一，海外渠道见 HuggingFaceClient）。
/// - 文件树：`GET modelscope.cn/api/v1/models/{ns}/{model}/repo/files?Recursive=true`
/// - 文件直链：`GET modelscope.cn/models/{ns}/{model}/resolve/master/{path}`
///   （LFS 大文件 302 → 带签名 CDN，签名约小时级时效——续传时重走 resolve 拿新 302）。
final class ModelScopeClient {
    static let host = "https://modelscope.cn"

    private let session: URLSession

    init(session: URLSession = ModelScopeClient.makeSession()) {
        self.session = session
    }

    /// 文件树接口不传凭据、体积小，短超时即可。
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }

    static func filesURL(repoID: String) -> URL {
        var comps = URLComponents(string: "\(host)/api/v1/models/\(repoID)/repo/files")!
        comps.queryItems = [URLQueryItem(name: "Recursive", value: "true")]
        return comps.url!
    }

    /// 文件直链（URLSession 默认跟随 302 到签名 CDN）。
    static func resolveURL(repoID: String, path: String) -> URL {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(host)/models/\(repoID)/resolve/master/\(escaped)")!
    }

    /// 拉取仓库全部 blob 文件（跳过目录节点与 .gitattributes 等仓库元数据）。
    func fetchFiles(repoID: String) async throws -> [ModelRepoFile] {
        let (data, response) = try await session.data(from: Self.filesURL(repoID: repoID))
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.decodeFileList(data)
    }

    /// 响应解析（包装结构 `{Code, Data:{Files:[...]}}`；Files 元素含目录节点 Type=tree）。
    static func decodeFileList(_ data: Data) throws -> [ModelRepoFile] {
        struct Wrapper: Codable {
            struct Payload: Codable {
                struct RawFile: Codable {
                    let Path: String
                    let Size: Int64?
                    let Sha256: String?
                    let IsLFS: Bool?
                    /// "blob" | "tree"（目录节点；属性名不能叫 Type——元类型语法冲突）。
                    let nodeType: String?

                    enum CodingKeys: String, CodingKey {
                        case Path, Size, Sha256, IsLFS
                        case nodeType = "Type"
                    }
                }
                let Files: [RawFile]?
            }
            let Code: Int?
            let Data: Payload?
        }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        let raw = wrapper.Data?.Files ?? []
        return raw.compactMap { file in
            guard file.nodeType == "blob" else { return nil }
            guard !file.Path.hasPrefix(".") else { return nil } // .gitattributes 等仓库元数据
            return ModelRepoFile(
                path: file.Path,
                size: file.Size ?? 0,
                sha256: file.Sha256,
                isLFS: file.IsLFS ?? false)
        }
    }
}
