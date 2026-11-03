import SwiftUI
import CloudDockCore

struct AuditView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var connection = "all"
    @State private var action = "all"
    @State private var status = "all"
    @State private var period = "all"
    @State private var selection: UUID?
    @State private var page = 0
    @State private var pageSize = 100
    @State private var result: AuditPage?
    @State private var loading = false
    @State private var loadError: String?

    private var records: [AuditRecord] { result?.records ?? [] }
    private var connections: [(id: String, name: String)] {
        (result?.connections ?? []).map { value in
            (id: value.id, name: store.connections.first(where: { $0.id.uuidString == value.id })?.name ?? value.name)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Label("所有操作", systemImage: "clock.arrow.circlepath").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if loading || (!store.auditReady && store.auditError == nil) { ProgressView().controlSize(.small) }
                    Text("\(result?.total ?? 0) 条记录").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("记录上传、下载、文件变更、下载分享及连接管理。浏览、刷新和预览不记录；清空传输队列不影响审计。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    TextField("搜索文件、路径或连接", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 140)
                    Picker("连接", selection: $connection) {
                        Text("全部连接").tag("all")
                        ForEach(connections, id: \.id) { item in Text(item.name).tag(item.id) }
                    }.labelsHidden().frame(width: 140)
                    Picker("操作", selection: $action) {
                        Text("全部操作").tag("all")
                        ForEach(AuditAction.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 115)
                    Picker("结果", selection: $status) {
                        Text("全部结果").tag("all")
                        ForEach(AuditStatus.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 125)
                    Picker("时间", selection: $period) {
                        Text("全部时间").tag("all"); Text("今天").tag("today"); Text("最近 7 天").tag("week")
                    }.labelsHidden().frame(width: 105)
                }.font(.system(size: 11))
                if let error = store.auditError { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange) }
                if let loadError { Label(loadError, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange) }
            }.padding(22)
            Divider()
            HStack(spacing: 12) {
                Text("时间").frame(width: 140, alignment: .leading)
                Text("操作").frame(width: 80, alignment: .leading)
                Text("所属连接").frame(width: 145, alignment: .leading)
                Text("操作对象").frame(maxWidth: .infinity, alignment: .leading)
                Text("结果").frame(width: 110, alignment: .leading)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 34)
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.clipboard").font(.system(size: 35, weight: .light)).foregroundStyle(.secondary)
                    Text(store.auditError != nil ? "审计暂不可用" : !store.auditReady ? "正在准备审计索引…" : loading ? "正在查询…" : store.auditCount == 0 ? "还没有操作审计" : "没有符合筛选条件的记录").font(.headline)
                    Text("审计按页查询，搜索和筛选覆盖全部历史记录。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(records) { record in
                        HStack(spacing: 12) {
                            Text(record.created.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second()))
                                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                            Text(record.action.rawValue).font(.system(size: 12, weight: .medium)).frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.connectionName).font(.system(size: 12)).lineLimit(1)
                                Text(record.provider.title).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.frame(width: 145, alignment: .leading)
                            Text(record.target).font(.system(size: 11)).lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                            Text(record.status.rawValue).font(.system(size: 11)).foregroundStyle(color(record.status)).frame(width: 110, alignment: .leading)
                        }.frame(minHeight: 42).tag(record.id).help(record.detail)
                    }
                }.listStyle(.inset).alternatingRowBackgrounds(.enabled)
            }
            Divider()
            PaginationBar(page: page, count: records.count, total: result?.total ?? 0,
                          hasNext: (page + 1) * pageSize < (result?.total ?? 0), loading: loading || !store.auditReady,
                          pageSize: $pageSize, previous: { page -= 1 }, next: { page += 1 })
            if let record = records.first(where: { $0.id == selection }) {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(record.action.rawValue) · \(record.connectionName) · \(record.status.rawValue)").font(.system(size: 12, weight: .semibold))
                        Text(record.target).font(.system(size: 11)).textSelection(.enabled)
                        Text(record.detail.isEmpty ? "等待执行结果。" : record.detail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("记录更新：\(record.updated.formatted()) · 连接 ID：\(record.connectionID.uuidString)").font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.frame(height: 145)
            }
        }.background(Color(nsColor: .textBackgroundColor))
            .onChange(of: [query, connection, action, status, period]) { _, _ in page = 0; selection = nil }
            .onChange(of: pageSize) { _, _ in page = 0; selection = nil }
            .onChange(of: page) { _, _ in selection = nil }
            .task(id: AuditRequest(terms: [query, connection, action, status, period], page: page, limit: pageSize, revision: store.auditRevision, ready: store.auditReady)) {
                guard store.auditReady else { return }
                loading = true; loadError = nil
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    var filter = AuditFilter(); filter.query = query; filter.page = page; filter.limit = pageSize
                    filter.connectionID = connection == "all" ? nil : connection
                    filter.action = action == "all" ? nil : action; filter.status = status == "all" ? nil : status
                    filter.since = period == "today" ? Calendar.current.startOfDay(for: Date()) : period == "week" ? Calendar.current.date(byAdding: .day, value: -7, to: Date()) : nil
                    let value = try await store.auditJournal.page(filter)
                    try Task.checkCancellation()
                    result = value; page = value.page; loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    loadError = error.localizedDescription; loading = false
                }
            }
    }
    private func color(_ status: AuditStatus) -> Color {
        switch status {
        case .completed: return .teal
        case .failed: return .red
        case .mixed, .skipped, .interrupted: return .orange
        case .running, .queued: return .blue
        default: return .secondary
        }
    }
}

private struct AuditRequest: Equatable {
    let terms: [String]
    let page: Int
    let limit: Int
    let revision: Int
    let ready: Bool
}
