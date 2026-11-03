import Foundation
import SQLite3

public struct AuditFilter: Sendable {
    public var query = ""
    public var connectionID: String?
    public var action: String?
    public var status: String?
    public var since: Date?
    public var page = 0
    public var limit = 100
    public init() {}
}
public struct AuditConnectionChoice: Identifiable, Sendable {
    public var id: String
    public var name: String
}
public struct AuditPage: Sendable {
    public var records: [AuditRecord]
    public var total: Int
    public var page: Int
    public var connections: [AuditConnectionChoice]
}

/// A rebuildable SQLite index of audit.jsonl. The original append-only journal remains authoritative.
final class AuditIndex {
    let file: URL
    private var writer: AuditDatabase?
    init(file: URL) { self.file = file }
    private func database() throws -> AuditDatabase {
        if let writer { return writer }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let db = try AuditDatabase(file: file)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, created REAL, updated REAL, connection_id TEXT, connection_name TEXT, action TEXT, status TEXT, search TEXT, payload TEXT)")
        try db.execute("CREATE INDEX IF NOT EXISTS records_created ON records(created DESC, id DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS records_connection ON records(connection_id, created DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS records_status ON records(status, created DESC)")
        try db.execute("CREATE TABLE IF NOT EXISTS checkpoint (id INTEGER PRIMARY KEY CHECK(id=1), offset INTEGER)")
        try db.execute("INSERT OR IGNORE INTO checkpoint VALUES(1, 0)")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        writer = db
        return db
    }
    func synchronize(journal: URL) throws {
        let db = try database()
        let size: Int64
        if FileManager.default.fileExists(atPath: journal.path) {
            size = (try FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? NSNumber)?.int64Value ?? 0
        } else { size = 0 }
        var offset = try db.integer("SELECT offset FROM checkpoint WHERE id=1")
        if offset > size {
            try db.transaction { try db.execute("DELETE FROM records"); try db.execute("UPDATE checkpoint SET offset=0 WHERE id=1") }
            offset = 0
        }
        guard size > offset else { return }
        let handle = try FileHandle(forReadingFrom: journal); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try db.transaction {
            var pending = Data(), consumed = offset
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end]); pending.removeSubrange(...end)
                    consumed += Int64(line.count + 1)
                    if line.isEmpty { continue }
                    let record: AuditRecord
                    do { record = try JSONDecoder().decode(AuditRecord.self, from: line) }
                    catch { throw CloudError.message("审计文件在字节 \(consumed) 附近无法解析，已保留原文件。") }
                    try put(record, db: db)
                }
                guard pending.count <= 8 * 1024 * 1024 else { throw CloudError.message("审计文件中有异常长的记录，已保留原文件。") }
            }
            guard pending.isEmpty else { throw CloudError.message("审计文件末尾记录不完整，已保留原文件。") }
            try db.execute("UPDATE checkpoint SET offset=? WHERE id=1", [.integer(consumed)])
        }
    }
    func append(_ record: AuditRecord, offset: UInt64) throws {
        let db = try database()
        try db.transaction {
            try put(record, db: db)
            try db.execute("UPDATE checkpoint SET offset=? WHERE id=1", [.integer(Int64(offset))])
        }
    }
    private func put(_ r: AuditRecord, db: AuditDatabase) throws {
        let payload = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        let search = [r.connectionName, r.target, r.detail, r.action.rawValue].joined(separator: "\n").lowercased()
        try db.execute("INSERT INTO records VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET created=excluded.created,updated=excluded.updated,connection_id=excluded.connection_id,connection_name=excluded.connection_name,action=excluded.action,status=excluded.status,search=excluded.search,payload=excluded.payload",
                       [.text(r.id.uuidString), .real(r.created.timeIntervalSince1970), .real(r.updated.timeIntervalSince1970), .text(r.connectionID.uuidString), .text(r.connectionName), .text(r.action.rawValue), .text(r.status.rawValue), .text(search), .text(payload)])
    }
    func page(_ filter: AuditFilter) throws -> AuditPage {
        guard (1...500).contains(filter.limit), filter.page >= 0 else { throw CloudError.message("审计分页参数无效。") }
        let db = try AuditDatabase(file: file, readOnly: true)
        var clauses: [String] = [], bindings: [AuditSQLValue] = []
        for (column, value) in [("connection_id", filter.connectionID), ("action", filter.action), ("status", filter.status)] {
            if let value { clauses.append("\(column)=?"); bindings.append(.text(value)) }
        }
        if let since = filter.since { clauses.append("created>=?"); bindings.append(.real(since.timeIntervalSince1970)) }
        if !filter.query.isEmpty { clauses.append("instr(search,?)>0"); bindings.append(.text(filter.query.lowercased())) }
        let condition = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        var records: [AuditRecord] = [], connections: [AuditConnectionChoice] = []
        var total = 0, page = 0
        try db.transaction(readOnly: true) {
            total = Int(try db.integer("SELECT COUNT(*) FROM records" + condition, bindings))
            page = min(filter.page, max(0, (total - 1) / filter.limit))
            try db.rows("SELECT payload FROM records" + condition + " ORDER BY created DESC,id DESC LIMIT ? OFFSET ?",
                        bindings + [.integer(Int64(filter.limit)), .integer(Int64(page * filter.limit))]) { row in
                records.append(try JSONDecoder().decode(AuditRecord.self, from: Data(row[0].utf8)))
            }
            // SQLite associates the bare name column with the row holding MAX(updated).
            try db.rows("SELECT connection_id,connection_name,MAX(updated) FROM records GROUP BY connection_id ORDER BY connection_name") { row in
                connections.append(AuditConnectionChoice(id: row[0], name: row[1]))
            }
        }
        return AuditPage(records: records, total: total, page: page, connections: connections)
    }
    func active() throws -> [AuditRecord] {
        let db = try AuditDatabase(file: file, readOnly: true)
        var values: [AuditRecord] = []
        try db.rows("SELECT payload FROM records WHERE status IN (?,?,?) LIMIT 100", [.text(AuditStatus.queued.rawValue), .text(AuditStatus.running.rawValue), .text(AuditStatus.paused.rawValue)]) { row in
            values.append(try JSONDecoder().decode(AuditRecord.self, from: Data(row[0].utf8)))
        }
        return values
    }
}

private enum AuditSQLValue { case text(String), integer(Int64), real(Double) }
private final class AuditDatabase {
    private var db: OpaquePointer?
    init(file: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(file.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw CloudError.message("无法打开本地审计索引。")
        }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_progress_handler(db, 1000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String, _ values: [AuditSQLValue] = []) throws { try rows(sql, values) { _ in } }
    func integer(_ sql: String, _ values: [AuditSQLValue] = []) throws -> Int64 {
        var value: Int64 = 0
        try rows(sql, values) { value = Int64($0[0]) ?? 0 }
        return value
    }
    func rows(_ sql: String, _ values: [AuditSQLValue] = [], body: ([String]) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1), result: Int32
            switch value {
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, slot, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let number): result = sqlite3_bind_int64(statement, slot, number)
            case .real(let number): result = sqlite3_bind_double(statement, slot, number)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result == SQLITE_INTERRUPT { throw CancellationError() }
            guard result == SQLITE_ROW else { throw failure() }
            let row = (0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            }
            try body(row)
        }
    }
    func transaction(readOnly: Bool = false, _ body: () throws -> Void) throws {
        try execute(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func failure() -> CloudError { .message("审计索引读写失败：" + String(cString: sqlite3_errmsg(db))) }
}
