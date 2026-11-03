import Foundation
import CloudDockCore

private actor PagingServiceFixture {
    var requests = 0
    var failNext = false
    var delay = false
    func setFailure() { failNext = true }
    func setDelay() { delay = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        if delay { try await Task.sleep(nanoseconds: 5_000_000_000) }
        let pairs = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let token = pairs.first { $0.name == "continuation-token" }?.value
        let limit = Int(pairs.first { $0.name == "max-keys" }!.value!)!
        let offset = token.flatMap { Int($0.replacingOccurrences(of: "opaque+/=", with: "")) } ?? 0
        if failNext { failNext = false; return (Data("fixture transient error".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!) }
        let end = min(251, offset + limit)
        let objects = (offset..<end).map { i in
            "<Contents><Key>folder/\(i == 205 || i == 250 ? "needle-" : "item-")\(i).txt</Key><Size>1</Size></Contents>"
        }.joined()
        let next = end < 251 ? "<NextContinuationToken>opaque+/=\(end)</NextContinuationToken>" : ""
        let xml = "<ListBucketResult><IsTruncated>\(end < 251)</IsTruncated>\(next)\(objects)</ListBucketResult>"
        return (Data(xml.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class PagingChecks {
    func testAuditIndexPaginationAndRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clouddock-audit-pages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("audit.jsonl")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        let connection = Connection(name: "audit pagination fixture", endpoint: "http://127.0.0.1:9000")
        var last = AuditRecord(connection: connection, action: .upload, target: "")
        for i in 0..<20_000 {
            var record = AuditRecord(connection: connection, action: .upload, target: "file-\(i) 中文", status: i == 19_999 ? .running : i % 10 == 0 ? .failed : .completed)
            record.created = Date(timeIntervalSince1970: 1_700_000_000 + Double(i)); record.updated = record.created
            var line = try JSONEncoder().encode(record); line.append(10); try handle.write(contentsOf: line)
            last = record
        }
        try handle.close()
        let before = try Data(contentsOf: file)
        let journal = AuditJournal(file: file)
        let start = Date()
        let first = try await journal.page(AuditFilter())
        print("Audit fixture: 20,000 records indexed in \(Int(Date().timeIntervalSince(start) * 1000)) ms; first page \(first.records.count) rows")
        expectEqual(first.total, 20_000); expectEqual(first.records.count, 100)
        expectEqual(first.records.first?.id, last.id)
        var filter = AuditFilter(); filter.page = 1
        let second = try await journal.page(filter)
        expectEqual(second.records.count, 100)
        expectTrue(Set(first.records.map(\.id)).isDisjoint(with: Set(second.records.map(\.id))))
        filter.page = 199
        let tail = try await journal.page(filter)
        expectEqual(tail.records.last?.target, "file-0 中文")
        filter = AuditFilter(); filter.query = "FILE-19999"
        let searched = try await journal.page(filter)
        expectEqual(searched.total, 1); expectEqual(searched.records.first?.id, last.id)
        filter = AuditFilter(); filter.status = AuditStatus.failed.rawValue
        expectEqual(try await journal.page(filter).total, 2000)
        expectEqual(try Data(contentsOf: file), before, file: #file, line: #line)

        // Simulate another version appending while the rebuildable index is behind.
        var added = AuditRecord(connection: connection, action: .download, target: "literal %_ marker", status: .completed)
        added.created = last.created.addingTimeInterval(1)
        let append = try FileHandle(forWritingTo: file); try append.seekToEnd()
        var line = try JSONEncoder().encode(added); line.append(10); try append.write(contentsOf: line); try append.close()
        let reopened = AuditJournal(file: file)
        expectEqual(try await reopened.page(AuditFilter()).total, 20_001)
        filter = AuditFilter(); filter.query = "%_"
        expectEqual(try await reopened.page(filter).records.first?.id, added.id)
        try reopened.recoverInterruptedOperations()
        filter = AuditFilter(); filter.status = AuditStatus.interrupted.rawValue
        expectEqual(try await reopened.page(filter).records.first?.id, last.id)
        filter = AuditFilter(); filter.page = 9999
        let clamped = try await reopened.page(filter)
        expectEqual(clamped.page, 200); expectEqual(clamped.records.count, 1)
        // A terminal update replaces the indexed lifecycle, without duplicating the operation.
        last.status = .completed; try reopened.append(last)
        filter = AuditFilter(); filter.status = AuditStatus.interrupted.rawValue
        expectEqual(try await reopened.page(filter).total, 0)
        expectEqual(try await reopened.page(AuditFilter()).total, 20_001)
        // A partial append is surfaced, not silently presented as an empty history.
        let broken = try FileHandle(forWritingTo: file); try broken.seekToEnd(); try broken.write(contentsOf: Data("{broken".utf8)); try broken.close()
        do { _ = try await reopened.page(AuditFilter()); fail("Partial audit record accepted") } catch {}
    }

    func testDemandPagingSearchRetryAndCancellation() async throws {
        let service = PagingServiceFixture()
        let engine = StorageEngine(objectListing: ObjectListingClient(transport: { try await service.send($0) }))
        let connection = Connection(name: "paging fixture", endpoint: "https://fixture.invalid")
        let credentials = Credentials(accessKey: "fixture", secretKey: "fixture")
        let first = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder")
        expectEqual(first.entries.count, 100); expectEqual(await service.requests, 1)
        let cursor = try required(first.next)
        await service.setFailure()
        do { _ = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder", cursor: cursor); fail("Expected failed next page") } catch {}
        let second = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder", cursor: cursor)
        expectEqual(second.entries.count, 100)
        expectTrue(Set(first.entries.map(\.id)).isDisjoint(with: Set(second.entries.map(\.id))))
        let third = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder", cursor: second.next)
        expectEqual(third.entries.count, 51); expectNil(third.next)
        let search = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder", query: "needle", limit: 50)
        expectEqual(Set(search.entries.map(\.path)), Set(["needle-205.txt", "needle-250.txt"]))
        expectNil(search.next)
        // Matching overflow is retained in the cursor, so the next result page loses no matches.
        let match = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder", query: "item-1", limit: 50)
        let matchNext = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder", query: "item-1", limit: 50, cursor: match.next)
        expectEqual(matchNext.entries.count, 50)
        expectTrue(Set(match.entries.map(\.id)).isDisjoint(with: Set(matchNext.entries.map(\.id))))
        let matchTail = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder", query: "item-1", limit: 50, cursor: matchNext.next)
        expectEqual(matchTail.entries.count, 11); expectNil(matchTail.next)
        expectEqual(Set((match.entries + matchNext.entries + matchTail.entries).map(\.id)).count, 111)
        await service.setDelay()
        let cancellation = Task { try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "folder", query: "never") }
        try await Task.sleep(nanoseconds: 20_000_000); cancellation.cancel()
        do { _ = try await cancellation.value; fail("Cancelled search completed") } catch is CancellationError {} catch { fail("Cancellation returned unexpected error: \(error)") }
    }

    func testNativePagesAgainstS3Fixture() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["CLOUDDOCK_TEST_ENDPOINT"] else { throw CheckSkipped("Requires isolated S3 fixture") }
        let engine = StorageEngine()
        let connection = Connection(name: "S3 paging fixture", endpoint: endpoint, region: "us-east-1")
        let credentials = Credentials(accessKey: "clouddock-fixture", secretKey: "fixture-only-not-a-real-secret")
        var cursor: DirectoryCursor?, seen = Set<String>(), pages = 0
        repeat {
            let result = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "paging", limit: 100, cursor: cursor)
            expectTrue(result.entries.count <= 100)
            for item in result.entries { expectTrue(seen.insert(item.id).inserted, "Repeated object across pages: \(item.id)") }
            cursor = result.next; pages += 1
            guard pages < 100 else { fail("Pagination did not terminate"); return }
        } while cursor != nil
        expectEqual(seen.count, 1210); expectEqual(pages, 13)
        expectTrue(seen.contains("object:资料 空+%&.txt"))
        expectTrue(seen.contains("object:same")); expectTrue(seen.contains("directory:same"))
        for key in ["entry1204.txt", "nested", "empty", "same"] {
            expectTrue(try await engine.nameExists(connection: connection, credentials: credentials, bucket: "fixture", key: "paging/" + key))
        }
        expectFalse(try await engine.nameExists(connection: connection, credentials: credentials, bucket: "fixture", key: "paging/entry1204"))
        let search = try await engine.directoryPage(connection: connection, credentials: credentials, bucket: "fixture", prefix: "paging", query: "资料")
        expectEqual(search.entries.map(\.path), ["资料 空+%&.txt"]); expectNil(search.next)
        print("S3 fixture: 1,210 file/folder entries returned in 13 bounded pages without duplicates")
    }
}
