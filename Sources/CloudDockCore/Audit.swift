import Foundation

public enum AuditAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case upload = "上传", download = "下载", createFolder = "新建文件夹", rename = "重命名", delete = "删除"
    case createConnection = "新增连接", updateConnection = "更新连接", removeConnection = "删除连接"
    case shareDownload = "分享下载"
    public var id: String { rawValue }
}

public enum AuditStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case queued = "等待中", running = "执行中", paused = "已暂停", completed = "成功", mixed = "完成（含跳过）"
    case skipped = "已跳过", failed = "失败", cancelled = "已取消", interrupted = "已中断"
    public var id: String { rawValue }
    public var active: Bool { self == .queued || self == .running || self == .paused }
}

/// Snapshot of non-secret context. Connection edits/removal cannot erase historical attribution.
public struct AuditRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var created: Date
    public var updated: Date
    public var connectionID: UUID
    public var connectionName: String
    public var provider: Provider
    public var action: AuditAction
    public var target: String
    public var status: AuditStatus
    public var detail: String
    public init(id: UUID = UUID(), connection: Connection, action: AuditAction, target: String,
                status: AuditStatus = .queued, detail: String = "") {
        self.id = id; created = Date(); updated = created
        connectionID = connection.id; connectionName = connection.name; provider = connection.provider
        self.action = action; self.target = target; self.status = status; self.detail = detail
    }
}

/// Append-only lifecycle events; never rewritten when the transfer queue is cleared.
public final class AuditJournal: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()
    private let index: AuditIndex
    public init(file: URL) { self.file = file; index = AuditIndex(file: file.appendingPathExtension("index.sqlite")) }
    public func prepare() throws {
        lock.lock(); defer { lock.unlock() }
        try index.synchronize(journal: file)
    }
    public func recoverInterruptedOperations() throws {
        try prepare()
        while true {
            let active = try index.active()
            if active.isEmpty { return }
            for var record in active {
                record.status = .interrupted; record.updated = Date()
                record.detail = "上次运行已结束，任务未取得完成结果；可手动重试。"
                try append(record)
            }
        }
    }
    public func page(_ filter: AuditFilter) async throws -> AuditPage {
        let work = Task.detached(priority: .userInitiated) { [self] in
            try prepare()
            return try index.page(filter)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
    public func load() throws -> [AuditRecord] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        var latest: [UUID: AuditRecord] = [:]
        for (index, line) in data.split(separator: 10).enumerated() {
            do { let record = try JSONDecoder().decode(AuditRecord.self, from: Data(line)); latest[record.id] = record }
            catch { throw CloudError.message("审计文件第 \(index + 1) 行无法解析，已保留原文件。") }
        }
        return latest.values.sorted { $0.created > $1.created }
    }
    public func append(_ record: AuditRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try index.synchronize(journal: file)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CloudError.message("无法创建本地审计文件。")
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = try JSONEncoder().encode(record); data.append(10)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try index.append(record, offset: handle.offset())
    }
}
