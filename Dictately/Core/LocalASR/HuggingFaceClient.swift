import Foundation

/// HuggingFace 匿名直链客户端（TASK-144 海外渠道）：mlx-community 原生组织在 HF
/// （ModelScope .cn 为镜像方；实测 .ai 国际站无 mlx-community、7 款目录模型全 404，
/// 故海外渠道是 HF 而非 modelscope.ai）。公开仓库无需 token。
/// 与 ModelScope 的差异（各自内聚，勿共用常量）：
/// - 默认分支 **main**（ModelScope 为 master）；
/// - 文件树响应为**裸数组**（无 `{Code,Data}` 包装）；
/// - sha256 仅 LFS 文件有（`lfs.oid`）；普通文件的 oid 是 git blob sha1，不作
///   下载校验——ModelRepoFile.sha256 = nil，校验环节自然跳过（既有分支）。
/// - 文件直链 `GET huggingface.co/{repo}/resolve/main/{path}`（307 → CDN 签名
///   直链，URLSession 自动跟随；续传重走 resolve 换新直链，与 .cn 同语义）。
final class HuggingFaceClient {
    static let host = "https://huggingface.co"
    /// HF 仓库默认分支（与 ModelScope 的 master 各自硬编码）。
    static let branch = "main"

    private let session: URLSession

    init(session: URLSession = HuggingFaceClient.makeSession()) {
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
        var comps = URLComponents(string: "\(host)/api/models/\(repoID)/tree/\(branch)")!
        comps.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        return comps.url!
    }

    /// 文件直链（URLSession 默认跟随 307 到签名 CDN）。
    static func resolveURL(repoID: String, path: String) -> URL {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(host)/\(repoID)/resolve/\(branch)/\(escaped)")!
    }

    /// 拉取仓库全部文件（跳过目录节点与 .gitattributes 等仓库元数据）。
    func fetchFiles(repoID: String) async throws -> [ModelRepoFile] {
        let (data, response) = try await session.data(from: Self.filesURL(repoID: repoID))
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.decodeTree(data)
    }

    /// 响应解析（2026-10-14 实测裸数组形态）：
    /// `[{"type":"file","oid":"…","size":N,"path":"…","lfs":{"oid":"sha256…","size":N}}]`
    /// 过滤 type=="file"（目录节点 type="directory"）+ 点开头仓库元数据；
    /// sha256 = lfs.oid（仅 LFS 有；普通文件 nil → 校验跳过）。
    /// 已知边界（有意不处理）：分页 Link header——目录 7 款仓库均 ≤13 文件，
    /// 远小于单页 1000 上限；新增模型若超限需在此补游标跟随。
    static func decodeTree(_ data: Data) throws -> [ModelRepoFile] {
        struct RawFile: Codable {
            struct LFS: Codable { let oid: String? }
            let type: String?
            let size: Int64?
            let path: String?
            let lfs: LFS?
        }
        let raw = try JSONDecoder().decode([RawFile].self, from: data)
        return raw.compactMap { file in
            guard file.type == "file", let path = file.path else { return nil }
            guard !path.hasPrefix(".") else { return nil } // .gitattributes 等仓库元数据
            return ModelRepoFile(
                path: path,
                size: file.size ?? 0,
                sha256: file.lfs?.oid,
                isLFS: file.lfs != nil)
        }
    }
}
