import Foundation
import CloudDockCore

extension AppStore {
    @discardableResult
    func beginAudit(connection: Connection, action: AuditAction, target: String,
                    status: AuditStatus = .queued, detail: String = "") throws -> UUID {
        if let auditError { throw CloudError.message("无法保存审计，操作尚未开始：\(auditError)") }
        guard auditReady else { throw CloudError.message("正在准备操作审计索引，请稍候再试。") }
        let record = AuditRecord(connection: connection, action: action, target: target, status: status, detail: detail)
        do { try auditJournal.append(record) }
        catch { auditError = error.localizedDescription; throw CloudError.message("无法保存审计，操作尚未开始：\(error.localizedDescription)") }
        activeAuditRecords[record.id] = record
        auditCount += 1; auditRevision += 1
        return record.id
    }
    func finishAudit(_ id: UUID?, status: AuditStatus, detail: String? = nil) {
        guard let id, var record = activeAuditRecords[id] else { return }
        record.status = status; record.updated = Date()
        if let detail { record.detail = detail }
        if status.active { activeAuditRecords[id] = record }
        else { activeAuditRecords.removeValue(forKey: id) }
        auditRevision += 1
        do { try auditJournal.append(record) }
        catch {
            auditError = error.localizedDescription
            alert = "操作状态已改变，但审计保存失败：\(error.localizedDescription)"
        }
    }
    func auditAction(for job: TransferJob) -> AuditAction? { AuditAction(rawValue: job.direction) }
    func auditTarget(for job: TransferJob) -> String {
        let source = job.arguments.count > 1 ? job.arguments[1] : job.name
        let destination = job.arguments.count > 2 ? job.arguments[2] : ""
        switch job.direction {
        case "上传": return "\(source) → \(destination)"
        case "下载": return "\(source) → \(destination)"
        case "重命名": return "\(source) → \(destination)"
        default: return source
        }
    }
    func auditPolicy(for job: TransferJob) -> String {
        if job.arguments.contains("--ignore-times") { return "已确认覆盖同名文件；强制重新传输。" }
        if job.arguments.contains("--ignore-existing") { return "跳过同名文件，已有内容保持不变。" }
        if job.arguments.contains("--immutable") { return "保留已有对象，不覆盖内容不同的文件。" }
        return ""
    }
}
