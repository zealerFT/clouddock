import Foundation
import CloudDockCore

final class S3IntegrationChecks {
    func testListedKeysDriveTransfersAndDeletion() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["CLOUDDOCK_COMPAT_ENDPOINT"] ?? environment["CLOUDDOCK_TEST_ENDPOINT"],
              let executable = environment["CLOUDDOCK_RCLONE"] else { throw CheckSkipped("Requires isolated S3 fixture") }
        let provider = Provider(rawValue: environment["CLOUDDOCK_COMPAT_PROVIDER"] ?? "minio")!
        let c = Connection(name: "local compatibility fixture", provider: provider, endpoint: endpoint, region: "us-east-1", pathStyle: false)
        let secret = Credentials(accessKey: "clouddock-fixture", secretKey: "fixture-only-not-a-real-secret")
        let engine = StorageEngine(executable: URL(fileURLWithPath: executable))
        let prefix = "compat-" + UUID().uuidString.lowercased()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(prefix)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let before = try await engine.directoryPage(connection: c, credentials: secret, bucket: "fixture", prefix: prefix)
        expectTrue(before.entries.isEmpty)
        expectNil(before.next)
        let names = ["截屏2026-10-30 15.28.41.txt", "截屏2026-10-30+15.28.41.txt", "%2B 空 格+&.txt",
                     "文件 夹+号/child 空 格+.txt", "文件+夹+号/child+.txt"]
        let source = temporary.appendingPathComponent("source.txt")
        for name in names {
            try Data(name.utf8).write(to: source)
            try await engine.run(["copyto", source.path, try ObjectPath.remote(bucket: "fixture", key: ObjectPath.join(prefix, name))], connection: c, credentials: secret)
        }
        // This is the UI's native paging -> selected row -> rclone path, not rclone's own listing.
        var cursor: DirectoryCursor?, entries: [RemoteEntry] = [], pages = 0
        repeat {
            let page = try await engine.directoryPage(connection: c, credentials: secret, bucket: "fixture", prefix: prefix, limit: 2, cursor: cursor)
            expectTrue(page.entries.count <= 2)
            entries += page.entries; cursor = page.next; pages += 1
            if pages > 10 { throw CloudError.message("Fixture pagination did not finish") }
        } while cursor != nil
        expectEqual(Set(entries.map(\.path)), Set(Array(names.prefix(3)) + ["文件 夹+号", "文件+夹+号"]))
        expectEqual(entries.count, 5)
        if entries.isEmpty {
            let legacy = try await engine.list(connection: c, credentials: secret, bucket: "fixture", recursive: true)
            print("Fixture rclone listing:", legacy.map(\.path))
        }
        for entry in entries where !entry.isDirectory {
            let key = ObjectPath.join(prefix, entry.path)
            expectTrue(try await engine.nameExists(connection: c, credentials: secret, bucket: "fixture", key: key))
            let bytes = try await engine.run(["cat", try ObjectPath.remote(bucket: "fixture", key: key)], connection: c, credentials: secret)
            expectEqual(bytes, Data(entry.path.utf8))
            let preview = try await engine.preview(connection: c, credentials: secret, bucket: "fixture", key: key, name: entry.name, size: entry.size)
            expectEqual(preview.data, bytes)
        }
        let spaced = try required(entries.first { $0.path == names[0] })
        try await engine.remove(connection: c, credentials: secret, bucket: "fixture", key: ObjectPath.join(prefix, spaced.path), directory: false)
        expectFalse(try await engine.nameExists(connection: c, credentials: secret, bucket: "fixture", key: ObjectPath.join(prefix, names[0])))
        expectTrue(try await engine.nameExists(connection: c, credentials: secret, bucket: "fixture", key: ObjectPath.join(prefix, names[1])))
        let plus = try required(entries.first { $0.path == names[1] })
        let renamed = "重命名 空 格+%2B.txt"
        try await engine.rename(connection: c, credentials: secret, bucket: "fixture", key: ObjectPath.join(prefix, plus.path), newName: renamed, directory: false)
        let refreshed = try await engine.directoryPage(connection: c, credentials: secret, bucket: "fixture", prefix: prefix)
        let renamedEntry = try required(refreshed.entries.first { $0.path == renamed })
        let share = try await engine.shareDownload(connection: c, credentials: secret, bucket: "fixture", key: ObjectPath.join(prefix, renamedEntry.path), validFor: 900)
        let (sharedBytes, response) = try await URLSession.shared.data(from: required(URL(string: share.address)))
        expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
        expectEqual(sharedBytes, Data(names[1].utf8))
        for directory in entries where directory.isDirectory {
            let childPrefix = ObjectPath.join(prefix, directory.path)
            let children = try await engine.directoryPage(connection: c, credentials: secret, bucket: "fixture", prefix: childPrefix)
            expectEqual(children.entries.count, 1)
            let child = try required(children.entries.first)
            let bytes = try await engine.run(["cat", try ObjectPath.remote(bucket: "fixture", key: ObjectPath.join(childPrefix, child.path))], connection: c, credentials: secret)
            expectEqual(bytes, Data(ObjectPath.join(directory.path, child.path).utf8))
            try await engine.remove(connection: c, credentials: secret, bucket: "fixture", key: childPrefix, directory: true)
        }
        for entry in refreshed.entries where !entry.isDirectory {
            try await engine.remove(connection: c, credentials: secret, bucket: "fixture", key: ObjectPath.join(prefix, entry.path), directory: false)
        }
        let final = try await engine.directoryPage(connection: c, credentials: secret, bucket: "fixture", prefix: prefix)
        expectTrue(final.entries.isEmpty)
        try await engine.remove(connection: c, credentials: secret, bucket: "fixture", key: prefix, directory: true)
        print("Local S3 fixture (\(provider.rawValue)): \(pages) pages; exact-key download, preview, rename, share and deletion verified")
    }

    func testTransferOutcomesAndBoundedPreview() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["CLOUDDOCK_TEST_ENDPOINT"],
              let executable = ProcessInfo.processInfo.environment["CLOUDDOCK_RCLONE"] else { throw CheckSkipped("Requires isolated S3 fixture") }
        let engine = StorageEngine(executable: URL(fileURLWithPath: executable))
        let c = Connection(name: "outcome fixture", endpoint: endpoint, region: "us-east-1")
        let secret = Credentials(accessKey: "clouddock-fixture", secretKey: "fixture-only-not-a-real-secret")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        let fixedDate = Date(timeIntervalSince1970: 1_600_000_000)
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        let remote = "cloud:fixture/outcomes/a.txt"
        let initial = try await engine.runResult(["copyto", file.path, remote, "--ignore-existing"], connection: c, credentials: secret)
        expectEqual(initial.stats?.transfers, 1)

        // Same filename, same length and same modtime, but different bytes.
        try Data("new".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        let skipped = try await engine.runResult(["copyto", file.path, remote, "--ignore-existing"], connection: c, credentials: secret)
        let skippedSummary = TransferSummary(stats: skipped.stats, skipsExisting: true, singleFile: true)
        expectEqual(skippedSummary.status, .skipped)
        expectEqual(skipped.stats?.transfers, 0)
        let oldPreview = try await engine.preview(connection: c, credentials: secret, bucket: "fixture", key: "outcomes/a.txt", name: "a.txt", size: 3)
        expectEqual(try PreviewPolicy.decodeText(oldPreview.data), "old")

        let replaced = try await engine.runResult(["copyto", file.path, remote, "--ignore-times"], connection: c, credentials: secret)
        expectEqual(replaced.stats?.transfers, 1)
        expectEqual(TransferSummary(stats: replaced.stats, skipsExisting: false).status, .completed)
        let updatedPreview = try await engine.preview(connection: c, credentials: secret, bucket: "fixture", key: "outcomes/a.txt", name: "a.txt", size: 3)
        expectEqual(try PreviewPolicy.decodeText(updatedPreview.data), "new")

        try Data("another".utf8).write(to: folder.appendingPathComponent("b.txt"))
        let mixed = try await engine.runResult(["copy", folder.path, "cloud:fixture/outcomes", "--ignore-existing"], connection: c, credentials: secret)
        expectEqual(mixed.stats?.transfers, 1)
        expectEqual(mixed.stats?.checks, 1)
        expectEqual(TransferSummary(stats: mixed.stats, skipsExisting: true).status, .mixed)

        let destination = folder.appendingPathComponent("download.txt")
        try Data("old".utf8).write(to: destination)
        let downloadSkip = try await engine.runResult(["copyto", remote, destination.path, "--ignore-existing"], connection: c, credentials: secret)
        expectEqual(TransferSummary(stats: downloadSkip.stats, skipsExisting: true, singleFile: true).status, .skipped)
        expectEqual(try String(contentsOf: destination), "old")
        _ = try await engine.runResult(["copyto", remote, destination.path, "--ignore-times"], connection: c, credentials: secret)
        expectEqual(try String(contentsOf: destination), "new")

        let journal = AuditJournal(file: folder.appendingPathComponent("audit.jsonl"))
        try journal.append(AuditRecord(connection: c, action: .upload, target: remote, status: skippedSummary.status, detail: skippedSummary.detail))
        expectEqual(try journal.load().first?.status, .skipped)
        // A stale listing must not allow unbounded preview data into the app.
        let large = folder.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 1024 * 1024 + 100).write(to: large)
        try await engine.run(["copyto", large.path, "cloud:fixture/outcomes/large.txt"], connection: c, credentials: secret)
        do {
            _ = try await engine.preview(connection: c, credentials: secret, bucket: "fixture", key: "outcomes/large.txt", name: "large.txt", size: 10)
            fail("Preview accepted stale-size oversized content")
        } catch { expectTrue(error.localizedDescription.contains("超过预览限制")) }
        try await engine.remove(connection: c, credentials: secret, bucket: "fixture", key: "outcomes", directory: true)
    }

    func testS3RoundTripDirectoriesRenameDeleteAndPresigning() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["CLOUDDOCK_TEST_ENDPOINT"],
              let executable = ProcessInfo.processInfo.environment["CLOUDDOCK_RCLONE"] else { throw CheckSkipped("Run python3 scripts/integration-test.py for isolated S3 integration tests") }
        let engine = StorageEngine(executable: URL(fileURLWithPath: executable))
        let c = Connection(name: "isolated fixture", endpoint: endpoint, region: "us-east-1")
        let secrets = Credentials(accessKey: "clouddock-fixture", secretKey: "fixture-only-not-a-real-secret")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("clouddock-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("local.txt")
        let bytes = Data("CloudDock 中文 & spaces\n\u{0} binary payload".utf8)
        try bytes.write(to: source)
        let buckets = try await engine.list(connection: c, credentials: secrets)
        expectTrue(buckets.contains { $0.path == "fixture" && $0.isDirectory })

        let key = "资料/空 格 &+ 文稿.txt"
        try await engine.run(["copyto", source.path, try ObjectPath.remote(bucket: "fixture", key: key)], connection: c, credentials: secrets)
        let root = try await engine.list(connection: c, credentials: secrets, bucket: "fixture")
        expectTrue(root.contains { $0.path == "资料" && $0.isDirectory })
        let directory = try await engine.list(connection: c, credentials: secrets, bucket: "fixture", prefix: "资料")
        expectEqual(directory.first(where: { !$0.isDirectory })?.name, "空 格 &+ 文稿.txt")
        let recursive = try await engine.list(connection: c, credentials: secrets, bucket: "fixture", recursive: true)
        expectTrue(recursive.contains { $0.path == key })

        let downloaded = temporary.appendingPathComponent("download.txt")
        try await engine.run(["copyto", try ObjectPath.remote(bucket: "fixture", key: key), downloaded.path], connection: c, credentials: secrets)
        expectEqual(try Data(contentsOf: downloaded), bytes)

        // A local same-name file must remain unchanged with the default skip policy.
        try Data("keep-existing".utf8).write(to: downloaded)
        try await engine.run(["copyto", try ObjectPath.remote(bucket: "fixture", key: key), downloaded.path, "--ignore-existing"], connection: c, credentials: secrets)
        expectEqual(try String(contentsOf: downloaded), "keep-existing")

        for duration in [900, 5400, 604800] {
            let share = try await engine.shareDownload(connection: c, credentials: secrets, bucket: "fixture", key: key, validFor: duration)
            let parts = try required(URLComponents(string: share.address))
            expectEqual(parts.queryItems?.first(where: { $0.name == "X-Amz-Expires" })?.value, String(duration))
            expectTrue(abs(try required(share.expiresAt).timeIntervalSinceNow - Double(duration)) < 10)
            let (data, response) = try await URLSession.shared.data(from: required(URL(string: share.address)))
            expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
            expectEqual(data, bytes)
        }

        try await engine.makeFolder(connection: c, credentials: secrets, bucket: "fixture", prefix: "", name: "空目录")
        let folders = try await engine.list(connection: c, credentials: secrets, bucket: "fixture")
        expectTrue(folders.contains { $0.path == "空目录" && $0.isDirectory }, "New empty folder must survive listing")

        try await engine.rename(connection: c, credentials: secrets, bucket: "fixture", key: key, newName: "renamed.txt", directory: false)
        let renamed = try await engine.list(connection: c, credentials: secrets, bucket: "fixture", prefix: "资料")
        expectTrue(renamed.contains { $0.path == "renamed.txt" })
        expectFalse(renamed.contains { $0.path == "空 格 &+ 文稿.txt" })
        try await engine.remove(connection: c, credentials: secrets, bucket: "fixture", key: "资料", directory: true)
        try await engine.remove(connection: c, credentials: secrets, bucket: "fixture", key: "空目录", directory: true)
        let remaining = try await engine.list(connection: c, credentials: secrets, bucket: "fixture", recursive: true)
        expectFalse(remaining.contains { $0.path.hasPrefix("资料/") })
    }

    func testCancellationStopsLongTransfer() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["CLOUDDOCK_TEST_ENDPOINT"],
              let executable = ProcessInfo.processInfo.environment["CLOUDDOCK_RCLONE"] else { throw CheckSkipped("Requires isolated S3 fixture") }
        let engine = StorageEngine(executable: URL(fileURLWithPath: executable))
        let c = Connection(name: "cancel fixture", endpoint: endpoint, region: "us-east-1")
        let secret = Credentials(accessKey: "clouddock-fixture", secretKey: "fixture-only-not-a-real-secret")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 1024 * 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = CommandHandle()
        let task = Task { try await engine.run(["copyto", file.path, "cloud:fixture/cancelled.bin", "--bwlimit", "8k"], connection: c, credentials: secret, handle: handle) }
        try await Task.sleep(nanoseconds: 600_000_000)
        handle.pause()
        try await Task.sleep(nanoseconds: 100_000_000)
        handle.resume()
        handle.cancel()
        do { _ = try await task.value; fail("Cancelled transfer reported success") }
        catch is CancellationError {}
        catch { fail("Unexpected error: \(error)") }
    }
}
