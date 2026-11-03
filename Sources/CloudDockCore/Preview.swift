import Foundation

public enum PreviewKind: String, Sendable {
    case text, image, pdf
    public var byteLimit: Int { self == .text ? 1024 * 1024 : 10 * 1024 * 1024 }
}

public enum PreviewPolicy {
    public static func kind(name: String, size: Int64) throws -> PreviewKind {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let kind: PreviewKind
        let text = ["txt", "md", "json", "jsonl", "csv", "tsv", "yaml", "yml", "xml", "log", "ini", "toml", "conf", "swift", "js", "ts", "tsx", "jsx", "py", "go", "rs", "java", "sh", "html", "htm", "css", "sql", "properties", "env"]
        if text.contains(ext) || ["readme", "license", ".gitignore", ".env", "dockerfile", "makefile"].contains(name.lowercased()) { kind = .text }
        else if ["png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff", "heic"].contains(ext) { kind = .image }
        else if ext == "pdf" { kind = .pdf }
        else { throw CloudError.message("暂不支持这种文件类型的预览，请下载后查看。支持文本、常见图片和 PDF。") }
        guard size >= 0, size <= Int64(kind.byteLimit) else {
            throw CloudError.message("文件超过预览大小限制：文本最多 1 MB，图片和 PDF 最多 10 MB。请下载后查看。")
        }
        return kind
    }
    public static func decodeText(_ data: Data) throws -> String {
        guard data.count <= PreviewKind.text.byteLimit else { throw CloudError.message("文本超过 1 MB 预览限制。") }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let text = String(data: data, encoding: .utf16) { return text }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw CloudError.message("文件不是可预览的 UTF-8 / UTF-16 文本，请下载后查看。")
        }
        return text
    }
}

public struct PreviewContent: Sendable {
    public let kind: PreviewKind
    public let data: Data
}

extension StorageEngine {
    public func preview(connection: Connection, credentials: Credentials, bucket: String, key: String,
                        name: String, size: Int64) async throws -> PreviewContent {
        let kind = try PreviewPolicy.kind(name: name, size: size)
        let data = try await run(["cat", try ObjectPath.remote(bucket: bucket, key: key), "--head", String(kind.byteLimit + 1)], connection: connection, credentials: credentials)
        guard data.count <= kind.byteLimit else { throw CloudError.message("文件已发生变化并超过预览限制，请下载后查看。") }
        return PreviewContent(kind: kind, data: data)
    }
}
