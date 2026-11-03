import Foundation
import CloudDockCore

struct ShareRequest: Identifiable {
    let id = UUID()
    let entry: RemoteEntry
    let connection: Connection
    let location: Location
}

extension AppStore {
    func shareDownload(_ entry: RemoteEntry) {
        guard let connection, let location, !entry.isDirectory, !location.bucket.isEmpty else { return }
        shareRequest = ShareRequest(entry: entry, connection: connection, location: location)
    }

    func generateShare(_ request: ShareRequest, seconds: Int) async throws -> DownloadShare {
        try SharePolicy.validate(seconds: seconds)
        guard connections.contains(request.connection) else { throw CloudError.message("连接设置已改变，请重新打开分享窗口。") }
        let key = ObjectPath.join(request.location.prefix, request.entry.path)
        let target = try ObjectPath.remote(bucket: request.location.bucket, key: key)
        let detail = request.connection.isLocalGoogleEndpoint ? "请求本地测试服务下载直链，无自动过期。" : "请求下载分享，有效期 \(seconds / 60) 分钟。"
        let auditID = try beginAudit(connection: request.connection, action: .shareDownload, target: target,
                                     status: .running, detail: detail)
        do {
            let share = try await engine.shareDownload(connection: request.connection, credentials: credentialStore.read(for: request.connection),
                                                      bucket: request.location.bucket, key: key, validFor: seconds)
            let result = share.expiresAt.map { "已生成下载分享，到期时间：\($0.formatted(date: .numeric, time: .standard))。" }
                ?? "已生成本地测试服务下载直链，无自动过期。"
            finishAudit(auditID, status: .completed, detail: result + "不保存分享地址。")
            return share
        } catch {
            finishAudit(auditID, status: error is CancellationError ? .cancelled : .failed,
                        detail: error is CancellationError ? "已取消生成下载分享。" : error.localizedDescription)
            throw error
        }
    }
}
