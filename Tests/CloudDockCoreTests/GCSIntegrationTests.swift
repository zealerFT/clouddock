import Foundation
import CloudDockCore

final class GCSIntegrationChecks {
    func testLocalGCSCompatibility() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["CLOUDDOCK_GCS_ENDPOINT"],
              let executable = environment["CLOUDDOCK_RCLONE"] else {
            throw CheckSkipped("Requires the disposable fake-gcs-server fixture")
        }
        var base = try required(URLComponents(string: endpoint)); base.path = ""
        let origin = try required(base.url?.absoluteString)
        let bucket = environment["CLOUDDOCK_GCS_BUCKET"] ?? "fixture"
        for suffix in ["", "/storage/v1", "/storage/v1/"] {
            try await roundTrip(endpoint: origin + suffix, executable: executable, bucket: bucket)
        }
    }

    private func roundTrip(endpoint: String, executable: String, bucket: String) async throws {
        let saved = Connection(name: "local GCS fixture", provider: .google, endpoint: endpoint, projectNumber: "demo-bucket")
        let connection = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(saved))
        // fake-gcs-server has no Google OAuth; the local endpoint is anonymous.
        // Keep this fixture credential-free so the test covers the same path as
        // a user connecting to the local Compose service.
        let credentials = Credentials()
        let engine = StorageEngine(executable: URL(fileURLWithPath: executable))
        let prefix = "compat-" + UUID().uuidString.lowercased()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(prefix)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let buckets = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "")
        expectTrue(buckets.entries.contains { $0.path == bucket && $0.isDirectory })

        let before = try await engine.directoryPage(connection: connection, credentials: credentials,
                                                    bucket: bucket, prefix: prefix)
        expectTrue(before.entries.isEmpty)

        let names = ["截屏 空 格.txt", "截屏+加号.txt", "目录 空 格/子文件+%2F &?.txt"]
        let source = temporary.appendingPathComponent("source.txt")
        for name in names {
            try Data(name.utf8).write(to: source)
            try await engine.run(["copyto", source.path,
                                  try ObjectPath.remote(bucket: bucket, key: ObjectPath.join(prefix, name))],
                                 connection: connection, credentials: credentials)
        }

        var cursor: DirectoryCursor?, entries: [RemoteEntry] = [], pages = 0
        repeat {
            let page = try await engine.directoryPage(connection: connection, credentials: credentials,
                                                      bucket: bucket, prefix: prefix, limit: 2,
                                                      cursor: cursor)
            expectTrue(page.entries.count <= 2)
            entries += page.entries; cursor = page.next; pages += 1
            if pages > 10 { throw CloudError.message("GCS fixture pagination did not finish") }
        } while cursor != nil
        expectEqual(Set(entries.map(\.path)), Set(["截屏 空 格.txt", "截屏+加号.txt", "目录 空 格"]))
        expectTrue(entries.contains { $0.path == "目录 空 格" && $0.isDirectory })

        for entry in entries where !entry.isDirectory {
            let key = ObjectPath.join(prefix, entry.path)
            expectTrue(try await engine.nameExists(connection: connection, credentials: credentials, bucket: bucket, key: key))
            let data = try await engine.run(["cat", try ObjectPath.remote(bucket: bucket, key: key)],
                                            connection: connection, credentials: credentials)
            expectEqual(data, Data(entry.path.utf8))
            let preview = try await engine.preview(connection: connection, credentials: credentials, bucket: bucket,
                                                   key: key, name: entry.name, size: entry.size)
            expectEqual(preview.data, data)
            let share = try await engine.shareDownload(connection: connection, credentials: credentials, bucket: bucket, key: key, validFor: 900)
            expectNil(share.expiresAt)
            let (shared, response) = try await URLSession.shared.data(from: required(URL(string: share.address)))
            expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
            expectEqual(shared, data)
        }

        let plus = try required(entries.first { $0.path == "截屏+加号.txt" })
        try await engine.rename(connection: connection, credentials: credentials, bucket: bucket,
                                key: ObjectPath.join(prefix, plus.path), newName: "重命名 空 格+.txt", directory: false)
        expectTrue(try await engine.nameExists(connection: connection, credentials: credentials, bucket: bucket,
                                               key: ObjectPath.join(prefix, "重命名 空 格+.txt")))
        try await engine.remove(connection: connection, credentials: credentials, bucket: bucket,
                                key: ObjectPath.join(prefix, "重命名 空 格+.txt"), directory: false)
        expectFalse(try await engine.nameExists(connection: connection, credentials: credentials, bucket: bucket,
                                                key: ObjectPath.join(prefix, "重命名 空 格+.txt")))

        // fake-gcs-server does not implement rclone's recursive purge endpoint
        // exactly like hosted GCS. Delete the child and its explicit marker by
        // their exact object keys, which exercises the same selected-key path.
        let directory = try required(entries.first { $0.path == "目录 空 格" && $0.isDirectory })
        let childKey = ObjectPath.join(prefix, directory.path) + "/子文件+%2F &?.txt"
        let childShare = try await engine.shareDownload(connection: connection, credentials: credentials, bucket: bucket, key: childKey, validFor: 900)
        let shareURL = try required(URL(string: childShare.address))
        let (sharedChild, childResponse) = try await URLSession.shared.data(from: shareURL)
        expectEqual((childResponse as? HTTPURLResponse)?.statusCode, 200)
        expectEqual(sharedChild, Data(names[2].utf8))
        try await engine.remove(connection: connection, credentials: credentials, bucket: bucket,
                                key: childKey, directory: false)
        let final = try await engine.directoryPage(connection: connection, credentials: credentials,
                                                   bucket: bucket, prefix: prefix)
        expectEqual(final.entries.map(\.path), ["截屏 空 格.txt"])
        let (_, removedResponse) = try await URLSession.shared.data(from: shareURL)
        expectEqual((removedResponse as? HTTPURLResponse)?.statusCode, 404)
        let remaining = try required(final.entries.first)
        try await engine.remove(connection: connection, credentials: credentials, bucket: bucket,
                                key: ObjectPath.join(prefix, remaining.path), directory: false)
        let empty = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: bucket, prefix: prefix)
        expectTrue(empty.entries.isEmpty)
        print("Local GCS \(endpoint): \(pages) pages; upload, download, preview, share, rename and deletion verified")
    }
}
