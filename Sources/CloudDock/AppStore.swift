import SwiftUI
import AppKit
import CloudDockCore

struct Location: Equatable {
    var connectionID: UUID
    var bucket: String = ""
    var prefix: String = ""
}

enum JobStatus: String, Codable {
    case queued = "等待中", running = "传输中", paused = "已暂停", completed = "已完成", mixed = "完成（含跳过）", skipped = "已跳过", failed = "失败", cancelled = "已取消", interrupted = "已中断"
    var active: Bool { self == .queued || self == .running || self == .paused }
    var succeeded: Bool { self == .completed || self == .mixed }
}
struct TransferJob: Identifiable, Codable {
    var id = UUID()
    var name: String
    var direction: String
    var connection: Connection
    var arguments: [String]
    var localPath: String?
    var status: JobStatus = .queued
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speed: Double = 0
    var error: String?
    var created = Date()
    var auditID: UUID?
    var resultSummary: String?
}

private struct SavedState: Codable {
    var connections: [Connection] = []
    var favorites: [Favorite] = []
    var jobs: [TransferJob] = []
}

@MainActor
final class AppStore: ObservableObject {
    @Published var connections: [Connection] = []
    @Published var favorites: [Favorite] = []
    @Published var location: Location?
    @Published var entries: [RemoteEntry] = []
    @Published var selected = Set<String>()
    @Published var query = ""
    @Published var recursive = false
    @Published var isLoading = false
    @Published var listError: String?
    @Published var alert: String?
    @Published var notice: String?
    @Published var jobs: [TransferJob] = []
    @Published var showTransfers = true
    @Published var showInspector = false
    @Published var showAudit = false
    @Published var auditCount = 0
    @Published var auditRevision = 0
    @Published var auditReady = false
    @Published var auditError: String?
    var activeAuditRecords: [UUID: AuditRecord] = [:]
    @Published var filePage = 0
    @Published var filePageSize = 100
    @Published var fileHasNext = false
    @Published var scannedEntries = 0
    @Published var previewRequest: PreviewRequest?
    @Published var shareRequest: ShareRequest?
    @Published var isPreparingTransfer = false
    @Published var sortField = "名称"
    @Published var descending = false
    @Published var isDropping = false
    @Published var history: [Location] = []
    @Published var forwardHistory: [Location] = []
    private var listing: Task<Void, Never>?
    private var listingID = UUID()
    private var pageCursors: [DirectoryCursor?] = [nil]
    private var searchTask: Task<Void, Never>?
    private var requestedQuery: String?
    private var handles: [UUID: CommandHandle] = [:]
    private var promiseCompletions: [UUID: (Error?) -> Void] = [:]
    let engine = StorageEngine()
    let credentialStore = CredentialStore()
    private let stateFile: URL
    let auditJournal: AuditJournal
    private var canPersist = true

    init() {
        stateFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudDock/state.json")
        auditJournal = AuditJournal(file: stateFile.deletingLastPathComponent().appendingPathComponent("audit.jsonl"))
        do {
            if FileManager.default.fileExists(atPath: stateFile.path) {
                let value = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateFile))
                connections = value.connections; favorites = value.favorites; jobs = value.jobs
                for i in jobs.indices where jobs[i].status.active { jobs[i].status = .interrupted; jobs[i].speed = 0 }
            }
        } catch {
            canPersist = false
            alert = "无法读取本地配置，已保留原文件：\(error.localizedDescription)"
        }
        // The selected location is UI session state and is intentionally not stored in
        // state.json. Restore a useful starting location from the first saved connection
        // so an existing setup never falls back to the empty welcome screen on launch.
        if let first = connections.first {
            location = Location(connectionID: first.id, bucket: first.bucket)
            reload()
        }
        let journal = auditJournal
        Task {
            do {
                try await Task.detached(priority: .utility) { try journal.recoverInterruptedOperations() }.value
                auditCount = try await journal.page(AuditFilter()).total
                auditReady = true; auditRevision += 1
            } catch { auditError = error.localizedDescription; alert = "无法读取操作审计：\(error.localizedDescription)" }
        }
    }
    var connection: Connection? { connections.first { $0.id == location?.connectionID } }
    var selectedEntries: [RemoteEntry] { visibleEntries.filter { selected.contains($0.id) } }
    var hasBucket: Bool { !showAudit && !(location?.bucket.isEmpty ?? true) }
    var activeCount: Int { jobs.filter { $0.status.active }.count }
    var visibleEntries: [RemoteEntry] {
        let filtered = entries.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let comparison: ComparisonResult
            switch sortField {
            case "大小": comparison = a.size == b.size ? a.path.localizedStandardCompare(b.path) : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case "修改时间": comparison = a.modified == b.modified ? a.path.localizedStandardCompare(b.path) : a.modified.compare(b.modified)
            default: comparison = a.path.localizedStandardCompare(b.path)
            }
            return descending ? comparison == .orderedDescending : comparison == .orderedAscending
        }
    }
    func persist() {
        do { try saveState() } catch { alert = "保存配置失败：\(error.localizedDescription)" }
    }
    private func saveState() throws {
        guard canPersist else { throw CloudError.message("本地配置无法读取，不能覆盖原配置。") }
            let folder = stateFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let retainedIDs = Set(jobs.filter { !$0.status.active }.suffix(200).map(\.id))
            let value = SavedState(connections: connections, favorites: favorites, jobs: jobs.filter { $0.status.active || retainedIDs.contains($0.id) })
            try JSONEncoder().encode(value).write(to: stateFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }
    func saveConnection(_ connection: Connection, credentials: Credentials?) throws {
        guard canPersist else { throw CloudError.message("本地配置无法读取，不能覆盖原配置。请先修复 state.json。") }
        try connection.validateConfiguration()
        if jobs.contains(where: { $0.connection.id == connection.id && $0.status.active }) {
            throw CloudError.message("该连接还有传输任务，请完成或取消后再编辑。")
        }
        let previous = connections
        let old = connections.first(where: { $0.id == connection.id })
        let target = old.map { $0.name == connection.name ? connection.name : "\($0.name) → \(connection.name)" } ?? connection.name
        var changes: [String] = []
        if let old {
            if old.name != connection.name { changes.append("名称：\(old.name) → \(connection.name)") }
            if old.provider != connection.provider { changes.append("服务：\(old.provider.title) → \(connection.provider.title)") }
            if old.endpoint != connection.endpoint { changes.append("Endpoint：\(old.endpoint) → \(connection.endpoint)") }
            if old.region != connection.region { changes.append("Region：\(old.region) → \(connection.region)") }
            if old.bucket != connection.bucket { changes.append("存储桶：\(old.bucket) → \(connection.bucket)") }
            if old.projectNumber != connection.projectNumber { changes.append("Google 项目编号已更新。") }
            if old.pathStyle != connection.pathStyle { changes.append("地址模式已更新。") }
            if old.credentialStorage != connection.credentialStorage { changes.append("凭据保存方式：\(old.credentialStorage.title) → \(connection.credentialStorage.title)") }
            if credentials != nil { changes.append("访问凭据已保存（不记录凭据内容）。") }
            if changes.isEmpty { changes.append("连接设置未变化，已重新保存。") }
        } else { changes.append("新增 \(connection.provider.title) 连接；访问凭据保存至\(connection.credentialStorage.title)。") }
        let auditID = try beginAudit(connection: connection, action: old == nil ? .createConnection : .updateConnection,
                                     target: target, status: .running, detail: changes.joined(separator: "\n"))
        do {
            let cleanupWarning = try credentialStore.save(credentials, connection: connection, replacing: old) {
                if let index = connections.firstIndex(where: { $0.id == connection.id }) { connections[index] = connection }
                else { connections.append(connection) }
                try saveState()
            }
            if let cleanupWarning { changes.append(cleanupWarning); alert = cleanupWarning }
        } catch {
            connections = previous
            finishAudit(auditID, status: .failed, detail: error.localizedDescription)
            throw error
        }
        finishAudit(auditID, status: .completed, detail: changes.joined(separator: "\n"))
        if credentials == nil {
            // Saving settings without reading a secret must not immediately request it via reload.
            if var old, location?.connectionID == connection.id {
                old.name = connection.name
                if old != connection {
                    listing?.cancel(); listingID = UUID(); isLoading = false
                    location = nil; entries = []; selected = []; listError = nil
                }
            }
            notice = "连接设置已保存。"
        } else {
            navigate(Location(connectionID: connection.id, bucket: connection.bucket))
        }
    }
    func removeConnection(_ c: Connection) {
        guard !jobs.contains(where: { $0.connection.id == c.id && $0.status.active }) else { alert = "请先结束该连接的传输任务。"; return }
        guard confirm("移除“\(c.name)”？", "移除本机连接、\(c.credentialStorage.title)中的凭据及关联收藏；云端文件不受影响。", action: "移除") else { return }
        var auditID: UUID?
        let previous = connections, previousFavorites = favorites
        do {
            auditID = try beginAudit(connection: c, action: .removeConnection, target: c.name, status: .running)
            try credentialStore.remove(c) {
                connections.removeAll { $0.id == c.id }; favorites.removeAll { $0.connectionID == c.id }
                try saveState()
            }
            if location?.connectionID == c.id {
                listing?.cancel()
                if let first = connections.first {
                    navigate(Location(connectionID: first.id, bucket: first.bucket), record: false)
                } else {
                    location = nil; entries = []; selected = []
                }
            }
            history.removeAll { $0.connectionID == c.id }; forwardHistory.removeAll { $0.connectionID == c.id }
            finishAudit(auditID, status: .completed, detail: "本机连接、\(c.credentialStorage.title)中的凭据及关联收藏已移除；云端对象未删除。")
        } catch {
            connections = previous; favorites = previousFavorites
            finishAudit(auditID, status: .failed, detail: error.localizedDescription)
            alert = error.localizedDescription
        }
    }
    func navigate(_ next: Location, record: Bool = true) {
        searchTask?.cancel()
        showAudit = false
        if record, let current = location, current != next { history.append(current); forwardHistory = [] }
        location = next; query = ""; recursive = false; selected = []; entries = []
        reload()
    }
    func back() { guard let last = history.popLast() else { return }; if let current = location { forwardHistory.append(current) }; navigate(last, record: false) }
    func forward() { guard let next = forwardHistory.popLast() else { return }; if let current = location { history.append(current) }; navigate(next, record: false) }
    func up() {
        guard var loc = location else { return }
        if !loc.prefix.isEmpty { loc.prefix = ObjectPath.parent(loc.prefix) }
        else if connection?.bucket.isEmpty == true { loc.bucket = "" }
        else { return }
        navigate(loc)
    }
    func open(_ entry: RemoteEntry) {
        guard var loc = location else { return }
        if loc.bucket.isEmpty { loc.bucket = entry.path }
        else if entry.isDirectory { loc.prefix = ObjectPath.join(loc.prefix, entry.path) }
        else {
            selected = [entry.id]
            if let connection { previewRequest = PreviewRequest(entry: entry, connection: connection, location: loc) }
            return
        }
        navigate(loc)
    }
    func reload() {
        searchTask?.cancel()
        pageCursors = [nil]; filePage = 0
        loadFilePage(0)
    }
    func scheduleSearch() {
        guard query != requestedQuery else { return }
        requestedQuery = nil
        searchTask?.cancel(); listing?.cancel(); listingID = UUID(); isLoading = false; fileHasNext = false; selected = []
        searchTask = Task {
            do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation() }
            catch { return }
            pageCursors = [nil]; filePage = 0; loadFilePage(0)
        }
    }
    func previousFilePage() { if filePage > 0 && !isLoading { loadFilePage(filePage - 1) } }
    func nextFilePage() { if fileHasNext && !isLoading { loadFilePage(filePage + 1) } }
    func retryListing() { loadFilePage(filePage) }
    private func loadFilePage(_ index: Int) {
        guard pageCursors.indices.contains(index) else { return }
        listing?.cancel()
        let token = UUID(); listingID = token
        guard let c = connection, let loc = location else { isLoading = false; return }
        filePage = index; isLoading = true; listError = nil; entries = []; selected = []; fileHasNext = false; scannedEntries = 0
        let recurse = recursive && !loc.bucket.isEmpty
        let query = query, limit = filePageSize, cursor = pageCursors[index]
        requestedQuery = query
        listing = Task {
            do {
                let secret = try credentialStore.read(for: c)
                let page = try await engine.directoryPage(connection: c, credentials: secret, bucket: loc.bucket, prefix: loc.prefix,
                                                          recursive: recurse, query: query, limit: limit, cursor: cursor) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.listingID == token, self.isLoading, progress.scanned >= self.scannedEntries else { return }
                        self.entries = progress.entries; self.scannedEntries = progress.scanned
                    }
                }
                guard listingID == token, !Task.isCancelled else { return }
                entries = page.entries; isLoading = false; fileHasNext = page.next != nil
                pageCursors = Array(pageCursors.prefix(index + 1))
                if let next = page.next { pageCursors.append(next) }
            } catch {
                guard listingID == token, !Task.isCancelled else { return }
                isLoading = false; listError = error.localizedDescription
            }
        }
    }
    func stopListing() { searchTask?.cancel(); listing?.cancel(); listingID = UUID(); isLoading = false; fileHasNext = false; listError = "已取消读取；当前结果可能不完整。" }
    func toggleFavorite() {
        guard let loc = location, let c = connection else { return }
        if let i = favorites.firstIndex(where: { $0.connectionID == c.id && $0.bucket == loc.bucket && $0.prefix == loc.prefix }) { favorites.remove(at: i) }
        else {
            let name = loc.prefix.split(separator: "/").last.map(String.init) ?? (loc.bucket.isEmpty ? c.name : loc.bucket)
            favorites.append(Favorite(connectionID: c.id, bucket: loc.bucket, prefix: loc.prefix, title: name))
        }
        persist()
    }
    var isFavorite: Bool { favorites.contains { $0.connectionID == location?.connectionID && $0.bucket == location?.bucket && $0.prefix == location?.prefix } }
    func removeFavorite(_ f: Favorite) { favorites.removeAll { $0.id == f.id }; persist() }
    func chooseUploads() {
        guard hasBucket else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.prompt = "上传"; panel.message = "选择文件或文件夹，上传到当前云端目录。"
        if panel.runModal() == .OK { upload(panel.urls) }
    }
    func upload(_ urls: [URL]) {
        guard let c = connection, let loc = location, !loc.bucket.isEmpty else { alert = "请先进入一个存储桶再上传。"; return }
        guard !isPreparingTransfer else { alert = "正在检查同名文件，请稍候再上传。"; return }
        isPreparingTransfer = true
        Task {
            defer { isPreparingTransfer = false }
            do {
                // Query exact names, including objects outside the current page.
                let secret = try credentialStore.read(for: c)
                var conflicts: [String] = []
                for name in Set(urls.map(\.lastPathComponent)) {
                    try ObjectPath.validateComponent(name)
                    if try await engine.nameExists(connection: c, credentials: secret, bucket: loc.bucket, key: ObjectPath.join(loc.prefix, name)) { conflicts.append(name) }
                }
                guard connections.contains(c) else { throw CloudError.message("连接设置已改变，请重新选择文件上传。") }
                guard let overwrite = collisionChoice(names: conflicts, destination: "\(c.name) / \(ObjectPath.join(loc.bucket, loc.prefix))") else { return }
                var pending: [TransferJob] = []
                for url in urls {
                    guard url.isFileURL else { continue }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw CloudError.message("请直接选择实际文件或目录，不上传符号链接。") }
                    try ObjectPath.validateComponent(url.lastPathComponent)
                    let remote = try ObjectPath.remote(bucket: loc.bucket, key: ObjectPath.join(loc.prefix, url.lastPathComponent))
                    var args = [values.isDirectory == true ? "copy" : "copyto", url.path, remote, "--transfers", "4"]
                    if values.isDirectory == true { args += ["--create-empty-src-dirs"] }
                    args += [overwrite ? "--ignore-times" : "--ignore-existing"]
                    pending.append(TransferJob(name: url.lastPathComponent, direction: "上传", connection: c, arguments: args, localPath: url.path))
                }
                try enqueue(pending)
            } catch { alert = error.localizedDescription }
        }
    }
    /// nil cancels; false keeps existing files; true always transfers after an explicit choice.
    func collisionChoice(names: [String], destination: String) -> Bool? {
        guard !names.isEmpty else { return false }
        let a = NSAlert()
        a.messageText = "发现 \(names.count) 个同名文件或目录"
        a.informativeText = "目标：\(destination)\n\n" + names.prefix(8).joined(separator: "\n")
            + (names.count > 8 ? "\n…" : "")
            + "\n\n跳过：保留已有文件，仅传输新增文件。\n覆盖：用本次文件替换已有同名文件，旧内容将被替换；同名目录按此规则合并。"
        a.alertStyle = .warning
        a.addButton(withTitle: "跳过同名")
        a.addButton(withTitle: "覆盖同名")
        a.addButton(withTitle: "取消")
        switch a.runModal() {
        case .alertFirstButtonReturn: return false
        case .alertSecondButtonReturn: return true
        default: return nil
        }
    }
    func downloadPreview(_ request: PreviewRequest) {
        download([request.entry], connection: request.connection, location: request.location)
    }
    func downloadSelection() {
        guard let c = connection, let loc = location, !loc.bucket.isEmpty, !selectedEntries.isEmpty else { return }
        download(selectedEntries, connection: c, location: loc)
    }
    private func download(_ items: [RemoteEntry], connection c: Connection, location loc: Location) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.prompt = "下载到此处"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let conflicts = items.filter { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.path).path) }.map(\.path)
            guard let overwrite = collisionChoice(names: conflicts, destination: destination.path) else { return }
            var pending: [TransferJob] = []
            // When both a folder and a descendant are selected, the folder already includes it.
            for item in items where !items.contains(where: { $0.isDirectory && item.path.hasPrefix($0.path + "/") }) {
                try ObjectPath.validateRelative(item.path)
                let target = destination.appendingPathComponent(item.path).standardizedFileURL
                guard target.path.hasPrefix(destination.standardizedFileURL.path + "/") else { throw CloudError.message("下载路径超出目标目录。") }
                let resolvedBase = destination.resolvingSymlinksInPath().standardizedFileURL.path
                guard target.resolvingSymlinksInPath().path.hasPrefix(resolvedBase + "/") else { throw CloudError.message("下载目标包含指向目录外的符号链接。") }
                let remote = try ObjectPath.remote(bucket: loc.bucket, key: ObjectPath.join(loc.prefix, item.path))
                var args = [item.isDirectory ? "copy" : "copyto", remote, target.path, "--transfers", "4"]
                if item.isDirectory { args += ["--create-empty-src-dirs"] }
                args += [overwrite ? "--ignore-times" : "--ignore-existing"]
                pending.append(TransferJob(name: item.path, direction: "下载", connection: c, arguments: args, localPath: target.path))
            }
            try enqueue(pending)
        } catch { alert = error.localizedDescription }
    }
    func enqueue(_ pending: [TransferJob]) throws {
        defer { if !jobs.isEmpty { showTransfers = true; persist(); startQueue() } }
        for var job in pending {
            guard let action = auditAction(for: job) else { throw CloudError.message("无法识别该操作的审计类型。") }
            job.auditID = try beginAudit(connection: job.connection, action: action, target: auditTarget(for: job), detail: auditPolicy(for: job))
            jobs.append(job)
        }
    }
    private func startQueue() {
        while handles.count < 2, let index = jobs.firstIndex(where: { $0.status == .queued }) {
            guard auditError == nil else { alert = "审计暂不可写，新的任务保持等待。"; return }
            let job = jobs[index], handle = CommandHandle()
            finishAudit(job.auditID, status: .running)
            guard auditError == nil else { return }
            handles[job.id] = handle; jobs[index].status = .running
            Task {
                do {
                    let secrets = try credentialStore.read(for: job.connection)
                    let result = try await engine.runResult(job.arguments, connection: job.connection, credentials: secrets, handle: handle) { [weak self] stats in
                        Task { @MainActor in self?.update(job.id, stats: stats) }
                    }
                    if job.direction == "上传" || job.direction == "下载" {
                        let summary = TransferSummary(stats: result.stats,
                                                      skipsExisting: job.arguments.contains("--ignore-existing") || job.arguments.contains("--immutable"),
                                                      singleFile: job.arguments.first == "copyto")
                        let status: JobStatus = summary.status == .skipped ? .skipped : summary.status == .mixed ? .mixed : .completed
                        finish(job.id, status: status, summary: summary.detail)
                    } else { finish(job.id, status: .completed, summary: "\(job.direction)已完成。") }
                } catch is CancellationError { finish(job.id, status: .cancelled) }
                catch { finish(job.id, status: .failed, error: error.localizedDescription) }
            }
        }
        persist()
    }
    private func update(_ id: UUID, stats: TransferStats) {
        guard let i = jobs.firstIndex(where: { $0.id == id && $0.status == .running }) else { return }
        jobs[i].bytes = stats.bytes ?? jobs[i].bytes; jobs[i].totalBytes = stats.totalBytes ?? jobs[i].totalBytes
        jobs[i].speed = stats.speed ?? 0
    }
    private func finish(_ id: UUID, status: JobStatus, error: String? = nil, summary: String? = nil) {
        handles.removeValue(forKey: id)
        if let completion = promiseCompletions.removeValue(forKey: id) {
            completion(status.succeeded ? nil : CloudError.message(error ?? summary ?? "下载已取消。"))
        }
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].status = status; jobs[i].error = error; jobs[i].speed = 0; jobs[i].resultSummary = summary
            let auditStatus: AuditStatus = status == .completed ? .completed : status == .mixed ? .mixed : status == .skipped ? .skipped : status == .cancelled ? .cancelled : .failed
            let result = error ?? summary ?? (status == .cancelled ? "操作已取消；可能已有部分文件完成。" : status.rawValue)
            finishAudit(jobs[i].auditID, status: auditStatus, detail: [auditPolicy(for: jobs[i]), result].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        persist(); startQueue()
        if status.succeeded { reload() }
    }
    func pause(_ job: TransferJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        if job.status == .running { handles[job.id]?.pause(); jobs[i].status = .paused }
        else if job.status == .paused { handles[job.id]?.resume(); jobs[i].status = .running }
        finishAudit(job.auditID, status: jobs[i].status == .paused ? .paused : .running)
        persist()
    }
    func cancel(_ job: TransferJob) {
        if let h = handles[job.id] { h.cancel() }
        else if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[i].status = .cancelled
            finishAudit(job.auditID, status: .cancelled, detail: "任务尚未执行，已取消。")
            promiseCompletions.removeValue(forKey: job.id)?(CloudError.message("下载已取消。"))
            persist()
        }
    }
    func retry(_ job: TransferJob) {
        guard !job.status.active else { return }
        guard let current = connections.first(where: { $0.id == job.connection.id }), current == job.connection else {
            alert = "原连接已移除或配置已改变，请重新发起任务。"; return
        }
        if job.direction == "删除", !confirm("重新删除“\(job.name)”？", "将再次尝试删除选定的云端对象。", action: "删除") { return }
        var next = job
        if (job.direction == "上传" || job.direction == "下载") && !job.arguments.contains("--ignore-existing") && !job.arguments.contains("--immutable") {
            guard confirm("重试并覆盖同名文件？", "此任务选择了覆盖，重新执行会替换目标同名文件的内容。", action: "覆盖并重试") else { return }
            if !next.arguments.contains("--ignore-times") { next.arguments.append("--ignore-times") }
        }
        next.id = UUID(); next.created = Date(); next.auditID = nil; next.status = .queued
        next.error = nil; next.resultSummary = nil; next.bytes = 0; next.totalBytes = 0; next.speed = 0
        do { try enqueue([next]) } catch { alert = error.localizedDescription }
    }
    func clearFinished() { jobs.removeAll { !$0.status.active }; persist() }
    func promiseDownload(entry: RemoteEntry, connection: Connection, location: Location, destination: URL, completion: @escaping (Error?) -> Void) {
        do {
            try ObjectPath.validateComponent(entry.name)
            let source = try ObjectPath.remote(bucket: location.bucket, key: ObjectPath.join(location.prefix, entry.path))
            let job = TransferJob(name: entry.name, direction: "下载", connection: connection,
                                  arguments: [entry.isDirectory ? "copy" : "copyto", source, destination.path, "--immutable"] + (entry.isDirectory ? ["--create-empty-src-dirs"] : []), localPath: destination.path)
            promiseCompletions[job.id] = completion
            do { try enqueue([job]) }
            catch { promiseCompletions.removeValue(forKey: job.id); throw error }
        } catch { completion(error) }
    }
    func shutdown() {
        listing?.cancel()
        for job in jobs where job.status.active { finishAudit(job.auditID, status: .interrupted, detail: "App 退出，任务中断；请检查结果后重试。") }
        for handle in handles.values { handle.cancel() }
        persist()
    }
    func createFolder(_ name: String) {
        guard let c = connection, let loc = location, !loc.bucket.isEmpty else { return }
        Task {
            var auditID: UUID?
            do {
                try ObjectPath.validateComponent(name)
                let secret = try credentialStore.read(for: c)
                guard try await !engine.nameExists(connection: c, credentials: secret, bucket: loc.bucket, key: ObjectPath.join(loc.prefix, name)) else {
                    throw CloudError.message("已有同名文件或目录。")
                }
                guard connections.contains(c) else { throw CloudError.message("连接设置已改变，请重试。") }
                let target = try ObjectPath.remote(bucket: loc.bucket, key: ObjectPath.join(loc.prefix, name))
                auditID = try beginAudit(connection: c, action: .createFolder, target: target, status: .running)
                try await engine.makeFolder(connection: c, credentials: secret, bucket: loc.bucket, prefix: loc.prefix, name: name)
                finishAudit(auditID, status: .completed, detail: "空文件夹已创建。")
                if location == loc { reload() }
                notice = "已创建文件夹“\(name)”"
            } catch { finishAudit(auditID, status: .failed, detail: error.localizedDescription); alert = error.localizedDescription }
        }
    }
    func rename(_ entry: RemoteEntry, to name: String) {
        guard let c = connection, let loc = location, !loc.bucket.isEmpty else { return }
        Task {
            do {
                try ObjectPath.validateComponent(name)
                let targetRelative = ObjectPath.join(ObjectPath.parent(entry.path), name)
                guard targetRelative != entry.path else { return }
                let secret = try credentialStore.read(for: c)
                guard try await !engine.nameExists(connection: c, credentials: secret, bucket: loc.bucket, key: ObjectPath.join(loc.prefix, targetRelative)) else {
                    throw CloudError.message("目标名称已经存在，不能合并或覆盖。")
                }
                guard connections.contains(c) else { throw CloudError.message("连接设置已改变，请重试。") }
                let source = try ObjectPath.remote(bucket: loc.bucket, key: ObjectPath.join(loc.prefix, entry.path))
                let target = try ObjectPath.remote(bucket: loc.bucket, key: ObjectPath.join(loc.prefix, targetRelative))
                guard confirm("重命名“\(entry.name)”？", "对象存储通过复制后删除原对象实现重命名；大目录需要一定时间。", action: "重命名") else { return }
                try enqueue([TransferJob(name: "\(entry.name) → \(name)", direction: "重命名", connection: c,
                                     arguments: [entry.isDirectory ? "move" : "moveto", source, target, "--immutable"] + (entry.isDirectory ? ["--create-empty-src-dirs", "--delete-empty-src-dirs"] : []), localPath: nil)])
            } catch { alert = error.localizedDescription }
        }
    }
    func deleteSelection() {
        guard let c = connection, let loc = location, !loc.bucket.isEmpty, !selectedEntries.isEmpty else { return }
        let items = selectedEntries
        guard confirm("删除选中的 \(items.count) 项？", "将从 \(c.name) / \(loc.bucket) 删除对象。文件夹内所有对象也会删除。此 App 不提供回收站。", action: "删除") else { return }
        do {
            var pending: [TransferJob] = []
            for item in items where !items.contains(where: { $0.isDirectory && item.path.hasPrefix($0.path + "/") }) {
                let key = ObjectPath.join(loc.prefix, item.path)
                guard !key.isEmpty else { continue }
                pending.append(TransferJob(name: item.path, direction: "删除", connection: c,
                                          arguments: [item.isDirectory ? "purge" : "deletefile", try ObjectPath.remote(bucket: loc.bucket, key: key)], localPath: nil))
            }
            try enqueue(pending)
        } catch { alert = error.localizedDescription }
    }
    func copyPath(_ entry: RemoteEntry? = nil) {
        guard let loc = location, let c = connection else { return }
        let scheme = c.provider == .google ? "gs" : c.provider == .aliyun ? "oss" : "s3"
        let key = entry.map { ObjectPath.join(loc.prefix, $0.path) } ?? loc.prefix
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(scheme)://\(ObjectPath.join(loc.bucket, key))", forType: .string)
        notice = "已复制对象路径"
    }
    func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.alertStyle = .warning
        a.addButton(withTitle: action); a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }
}

func sizeString(_ bytes: Int64) -> String { bytes < 0 ? "—" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
