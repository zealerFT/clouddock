import Foundation

public struct DirectoryCursor: Sendable {
    var token: String?
    var started = false
    var pending: [RemoteEntry] = []
    public init() {}
}
public struct DirectoryPage: Sendable {
    public var entries: [RemoteEntry]
    public var next: DirectoryCursor?
}
public struct DirectoryProgress: Sendable {
    public var entries: [RemoteEntry]
    public var scanned: Int
}

extension StorageEngine {
    /// Search fills one result page at a time; no complete directory is retained in memory.
    public func directoryPage(connection: Connection, credentials: Credentials, bucket: String, prefix: String = "",
                              recursive: Bool = false, query: String = "", limit: Int = 100, cursor: DirectoryCursor? = nil,
                              progress: (@Sendable (DirectoryProgress) -> Void)? = nil) async throws -> DirectoryPage {
        guard (1...500).contains(limit) else { throw CloudError.message("每页数量应为 1–500。") }
        try ObjectPath.validateRelative(prefix)
        var state = cursor ?? DirectoryCursor(), entries: [RemoteEntry] = []
        var scanned = 0
        let base = prefix.isEmpty ? "" : prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        while entries.count < limit {
            try Task.checkCancellation()
            let take = min(limit - entries.count, state.pending.count)
            entries.append(contentsOf: state.pending.prefix(take)); state.pending.removeFirst(take)
            if entries.count == limit || (state.started && state.token == nil) { break }
            let previous = state.token
            let raw: ObjectPage
            if bucket.isEmpty {
                if connection.provider == .google {
                    raw = try await objectListing.bucketPage(connection: connection, credentials: credentials,
                                                             token: state.token, limit: limit)
                } else {
                    // ListBuckets has no portable continuation API. Object directories use native cursors below.
                    let buckets = try await list(connection: connection, credentials: credentials)
                    let start = state.token.flatMap(Int.init) ?? 0
                    guard start >= 0 else { throw CloudError.message("存储桶分页位置无效。") }
                    let end = min(start + limit, buckets.count)
                    raw = ObjectPage(entries: Array(buckets.dropFirst(start).prefix(limit)), nextToken: end < buckets.count ? String(end) : nil)
                }
            } else {
                raw = try await objectListing.page(connection: connection, credentials: credentials, bucket: bucket, prefix: base,
                                                   recursive: recursive, token: state.token, limit: limit)
            }
            if let next = raw.nextToken, next == previous { throw CloudError.message("服务端重复返回同一分页游标，已停止读取。请刷新重试。") }
            state.started = true; state.token = raw.nextToken; scanned += raw.entries.count
            state.pending = raw.entries.compactMap { value in
                let path: String
                if bucket.isEmpty { path = value.path }
                else {
                    guard value.path.hasPrefix(base) else { return nil }
                    path = String(value.path.dropFirst(base.count))
                }
                guard !path.isEmpty, query.isEmpty || path.localizedCaseInsensitiveContains(query) else { return nil }
                return RemoteEntry(path: path, size: value.size, modified: value.modified, isDirectory: value.isDirectory, mimeType: value.mimeType)
            }
            let available = Array((entries + state.pending).prefix(limit))
            progress?(DirectoryProgress(entries: available, scanned: scanned))
            // A browse request reads exactly one service page. A search continues until its result page is filled.
            if query.isEmpty {
                let take = min(limit - entries.count, state.pending.count)
                entries.append(contentsOf: state.pending.prefix(take)); state.pending.removeFirst(take)
                break
            }
        }
        return DirectoryPage(entries: entries, next: !state.pending.isEmpty || state.token != nil ? state : nil)
    }

    /// Checks only the exact object and its directory prefix, including names beyond the visible page.
    public func nameExists(connection: Connection, credentials: Credentials, bucket: String, key: String) async throws -> Bool {
        try ObjectPath.validateRelative(key)
        let first = try await objectListing.page(connection: connection, credentials: credentials, bucket: bucket, prefix: key,
                                                recursive: true, token: nil, limit: 1)
        if first.entries.contains(where: { $0.path == key }) { return true }
        let directory = try await objectListing.page(connection: connection, credentials: credentials, bucket: bucket, prefix: key + "/",
                                                    recursive: true, token: nil, limit: 1)
        return !directory.entries.isEmpty
    }
}
