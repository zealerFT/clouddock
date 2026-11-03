import Foundation
import CloudDockCore

final class AuditPreviewChecks {
    func testAuditPersistsSnapshotsAndReadingDoesNotLog() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("audit.jsonl")
        let journal = AuditJournal(file: file)
        expectEqual(try journal.load().count, 0)
        expectFalse(FileManager.default.fileExists(atPath: file.path), "Viewing audit must not create an operation")
        var c = Connection(name: "original connection", endpoint: "http://127.0.0.1:9000")
        var upload = AuditRecord(connection: c, action: .upload, target: "cloud:bucket/report.txt")
        try journal.append(upload)
        upload.status = .skipped; upload.detail = "同名文件已跳过，原内容保持不变。"
        try journal.append(upload)
        c.name = "renamed connection"
        try journal.append(AuditRecord(connection: c, action: .updateConnection, target: "original → renamed", status: .completed))
        try journal.append(AuditRecord(connection: c, action: .removeConnection, target: c.name, status: .completed))
        let before = try Data(contentsOf: file)
        let restored = try AuditJournal(file: file).load()
        expectEqual(restored.count, 3)
        expectEqual(restored.first(where: { $0.id == upload.id })?.connectionName, "original connection")
        expectEqual(restored.first(where: { $0.id == upload.id })?.status, .skipped)
        expectEqual(try Data(contentsOf: file), before)
        let raw = String(decoding: before, as: UTF8.self)
        expectFalse(raw.contains("secretKey")); expectFalse(raw.contains("serviceAccountJSON"))
        expectFalse(AuditAction.allCases.contains { ["浏览", "预览", "刷新", "查看"].contains($0.rawValue) })
        expectEqual(before.split(separator: 10).count, 4)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken\n".utf8)); try handle.close()
        expectThrows(try journal.load())
    }
    func testPreviewPolicyAndTextDecoding() throws {
        expectEqual(try PreviewPolicy.kind(name: "README.md", size: 1024), .text)
        expectEqual(try PreviewPolicy.kind(name: "image.PNG", size: 10 * 1024 * 1024), .image)
        expectEqual(try PreviewPolicy.kind(name: "manual.pdf", size: 10), .pdf)
        expectThrows(try PreviewPolicy.kind(name: "archive.zip", size: 1))
        expectThrows(try PreviewPolicy.kind(name: "vector.svg", size: 1))
        expectThrows(try PreviewPolicy.kind(name: "huge.txt", size: 1024 * 1024 + 1))
        expectThrows(try PreviewPolicy.kind(name: "huge.pdf", size: 10 * 1024 * 1024 + 1))
        expectThrows(try PreviewPolicy.kind(name: "unknown.txt", size: -1))
        expectEqual(try PreviewPolicy.decodeText(Data("中文 <script>text only</script>".utf8)), "中文 <script>text only</script>")
        expectEqual(try PreviewPolicy.decodeText(Data([0xff, 0xfe, 0x41, 0x00])), "A")
        expectThrows(try PreviewPolicy.decodeText(Data([0, 1, 2])))
        expectThrows(try PreviewPolicy.decodeText(Data(repeating: 65, count: 1024 * 1024 + 1)))
    }
}
