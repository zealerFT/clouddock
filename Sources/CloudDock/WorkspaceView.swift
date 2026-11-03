import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloudDockCore

extension Provider {
    var tint: Color {
        switch self {
        case .minio: return Color(red: 0.82, green: 0.22, blue: 0.31)
        case .aws: return .orange
        case .aliyun: return Color(red: 0.95, green: 0.35, blue: 0.13)
        case .google: return .blue
        case .compatible: return .purple
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @State private var editing: Connection?
    @State private var showConnection = false
    @State private var editorIdentity = UUID()
    @State private var folderPrompt = false
    @State private var renamePrompt = false
    @State private var fieldValue = ""
    @State private var renameTarget: RemoteEntry?
    private let teal = Color(red: 0.08, green: 0.52, blue: 0.48)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                titlebar
                Divider()
                if store.showAudit { AuditView() }
                else if store.connections.isEmpty { welcome }
                else { browser }
                if store.showTransfers && !store.showAudit { Divider(); TransferPanel() }
                statusbar
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(teal)
        .sheet(isPresented: $showConnection) {
            // A sheet presented with only a Bool keeps its content identity. Give each
            // edit/new action a fresh identity so ConnectionEditor cannot reuse an old
            // @State draft (which could otherwise overwrite a saved connection).
            ConnectionEditor(existing: editing).id(editorIdentity).environmentObject(store)
        }
        .sheet(item: $store.previewRequest) { request in FilePreviewView(request: request).environmentObject(store) }
        .sheet(item: $store.shareRequest) { request in ShareDownloadView(request: request).environmentObject(store) }
        .alert("CloudDock", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("好", role: .cancel) { store.alert = nil }
        } message: { Text(store.alert ?? "") }
        .alert("新建文件夹", isPresented: $folderPrompt) {
            TextField("文件夹名称", text: $fieldValue)
            Button("创建") { store.createFolder(fieldValue) }
            Button("取消", role: .cancel) {}
        } message: { Text("将在当前目录创建一个空文件夹。") }
        .alert("重命名", isPresented: $renamePrompt) {
            TextField("新名称", text: $fieldValue)
            Button("继续") { if let entry = renameTarget { store.rename(entry, to: fieldValue) } }
            Button("取消", role: .cancel) {}
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 28)).foregroundStyle(teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CloudDock").font(.system(size: 19, weight: .bold))
                    Text("所有云端文件，一处管理").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.top, 44).padding(.horizontal, 21).padding(.bottom, 24)
            Button { openConnectionEditor(nil) } label: {
                Label("新建连接", systemImage: "plus").fontWeight(.medium).frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).padding(.horizontal, 16).padding(.bottom, 25)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("云存储连接", count: store.connections.count)
                    if store.connections.isEmpty {
                        Text("添加一个云账号，开始管理文件").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 12)
                    }
                    ForEach(store.connections) { c in
                        Button { store.navigate(Location(connectionID: c.id, bucket: c.bucket)) } label: {
                            HStack(spacing: 10) {
                                Text(c.provider.shortName).font(.system(size: 9, weight: .heavy)).frame(width: 35, height: 34)
                                    .background(c.provider.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(c.provider.tint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(c.provider.title).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if c.id == store.location?.connectionID && !store.showAudit { Circle().fill(teal).frame(width: 6, height: 6) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(c.id == store.location?.connectionID && !store.showAudit ? teal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            // Transparent space must behave the same in selected and unselected rows.
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Text(c.name)
                                Divider()
                                Button("编辑连接…") { openConnectionEditor(c) }
                                Button("移除连接…", role: .destructive) { store.removeConnection(c) }
                            }
                    }
                    sectionLabel("收藏位置", count: store.favorites.count).padding(.top, 24)
                    if store.favorites.isEmpty {
                        Text("点击目录旁的星标，即可收藏").font(.system(size: 11)).foregroundStyle(.tertiary).padding(12)
                    }
                    ForEach(store.favorites) { favorite in
                        Button { store.navigate(Location(connectionID: favorite.connectionID, bucket: favorite.bucket, prefix: favorite.prefix)) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "star.fill").foregroundStyle(.orange).font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(favorite.title).lineLimit(1).font(.system(size: 12))
                                    Text(store.connections.first(where: { $0.id == favorite.connectionID })?.name ?? "连接已移除").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu { Button("取消收藏") { store.removeFavorite(favorite) } }
                    }
                }.padding(.horizontal, 10)
            }
            Divider().padding(.horizontal, 16)
            Button { store.showAudit = true } label: {
                HStack {
                    Label("操作审计", systemImage: "clock.arrow.circlepath").font(.system(size: 12))
                    Spacer()
                    Text("\(store.auditCount)").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(12).background(store.showAudit ? teal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 8)
            Button {
                if store.showAudit { store.showAudit = false; store.showTransfers = true }
                else { store.showTransfers.toggle() }
            } label: {
                HStack {
                    Label("传输任务", systemImage: "arrow.up.arrow.down.circle").font(.system(size: 12))
                    Spacer()
                    if store.activeCount > 0 { Text("\(store.activeCount)").font(.caption).padding(.horizontal, 6).background(teal.opacity(0.12), in: Capsule()) }
                }.padding(18)
            }.buttonStyle(.plain)
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").foregroundStyle(teal)
                Text(store.connection.map { "凭据：\($0.credentialStorage.title)" } ?? "凭据可选本机或钥匙串").foregroundStyle(.secondary)
            }.font(.system(size: 10)).padding(.horizontal, 18).padding(.bottom, 18)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack { Text(title); Spacer(); Text("\(count)").monospacedDigit() }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
    }
    private var titlebar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.showAudit ? "操作审计" : (store.connection?.name ?? "你的云端工作台")).font(.system(size: 19, weight: .semibold))
                Text(store.showAudit ? "查看发生了什么、属于哪个连接，以及实际执行结果" : (store.connection?.provider.title ?? "连接多种对象存储，像管理本地文件一样工作"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let c = store.connection, !store.showAudit {
                Button { openConnectionEditor(c) } label: { Image(systemName: "slider.horizontal.3") }.help("编辑当前连接")
                Button { store.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("文件详情")
            }
        }.buttonStyle(.borderless).padding(.horizontal, 25).padding(.top, 22).padding(.bottom, 19)
    }
    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 26).fill(teal.opacity(0.08)).frame(width: 104, height: 104)
                Image(systemName: "externaldrive.badge.icloud").font(.system(size: 45, weight: .light)).foregroundStyle(teal)
            }
            VStack(spacing: 9) {
                Text("文件在不同的云，工作留在一个窗口").font(.system(size: 24, weight: .semibold))
                Text("添加连接后，即可浏览存储桶、拖拽上传、下载与收藏常用目录。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach([Provider.minio, .aliyun, .aws, .google, .compatible]) { provider in
                    Text(provider.title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(provider.tint.opacity(0.08), in: Capsule()).foregroundStyle(provider.tint)
                }
            }
            Button { openConnectionEditor(nil) } label: { Label("添加第一个连接", systemImage: "plus").padding(.horizontal, 13).padding(.vertical, 5) }.buttonStyle(.borderedProminent)
            Text("文件直接在你的 Mac 与存储服务之间传输").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
    private func openConnectionEditor(_ connection: Connection?) {
        editing = connection
        editorIdentity = UUID()
        showConnection = true
    }
    private var browser: some View {
        VStack(spacing: 0) {
            breadcrumbs
            toolsBar
            Divider()
            HStack(spacing: 0) {
                fileList
                if store.showInspector { Divider(); inspector.frame(width: 236) }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $store.isDropping) { providers in
            guard store.hasBucket else { return false }
            let target = store.location
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    guard let url else { store.alert = "无法读取拖入的文件，请重新选择。"; return }
                    urls.append(url)
                }
                guard store.location == target && store.hasBucket else { store.alert = "目录已切换，请重新拖入文件。"; return }
                if !urls.isEmpty { store.upload(urls) }
            }
            return true
        }
        .overlay {
            if store.isDropping {
                RoundedRectangle(cornerRadius: 12).fill(teal.opacity(0.13)).overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.up.doc.fill").font(.system(size: 40))
                        Text("松开以上传到当前目录").font(.title3.bold())
                    }.foregroundStyle(teal)
                }.padding(10).allowsHitTesting(false)
            }
        }
    }
    private var breadcrumbs: some View {
        HStack(spacing: 10) {
            Button(action: store.back) { Image(systemName: "chevron.left") }.disabled(store.history.isEmpty).help("后退")
            Button(action: store.forward) { Image(systemName: "chevron.right") }.disabled(store.forwardHistory.isEmpty).help("前进")
            Button(action: store.up) { Image(systemName: "arrow.up") }.help("上一级")
            Divider().frame(height: 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let loc = store.location {
                        Button { if let c = store.connection { store.navigate(Location(connectionID: c.id, bucket: c.bucket)) } } label: {
                            Image(systemName: "externaldrive")
                            if loc.bucket.isEmpty { Text("存储桶") }
                        }
                        if !loc.bucket.isEmpty {
                            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                            Button(loc.bucket) { store.navigate(Location(connectionID: loc.connectionID, bucket: loc.bucket)) }
                            let components = loc.prefix.split(separator: "/").map(String.init)
                            ForEach(Array(components.enumerated()), id: \.offset) { i, part in
                                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                                Button(part) { store.navigate(Location(connectionID: loc.connectionID, bucket: loc.bucket, prefix: components.prefix(i + 1).joined(separator: "/"))) }
                            }
                        }
                    }
                }.lineLimit(1)
            }
            Button(action: store.toggleFavorite) { Image(systemName: store.isFavorite ? "star.fill" : "star").foregroundStyle(store.isFavorite ? .orange : .secondary) }.help("收藏当前目录")
            Button { store.copyPath() } label: { Image(systemName: "link") }.help("复制当前路径")
            if store.isLoading { ProgressView().controlSize(.small); Button(action: store.stopListing) { Image(systemName: "xmark") }.help("停止读取") }
            else { Button(action: store.reload) { Image(systemName: "arrow.clockwise") }.help("刷新 ⌘R") }
        }.font(.system(size: 12)).buttonStyle(.borderless).padding(.horizontal, 23).padding(.vertical, 13)
    }
    private var toolsBar: some View {
        HStack(spacing: 9) {
            Button(action: store.chooseUploads) { Label(store.isPreparingTransfer ? "检查同名…" : "上传", systemImage: "arrow.up") }.buttonStyle(.borderedProminent).disabled(!store.hasBucket || store.isPreparingTransfer)
            Button(action: store.downloadSelection) { Label("下载", systemImage: "arrow.down") }.disabled(!store.hasBucket || store.selectedEntries.isEmpty)
            Button { if let entry = store.selectedEntries.first { store.shareDownload(entry) } } label: { Label("分享下载", systemImage: "square.and.arrow.up") }
                .disabled(!store.hasBucket || store.selectedEntries.count != 1 || store.selectedEntries.first?.isDirectory != false)
                .help("分享下载地址或二维码")
            Button { fieldValue = ""; folderPrompt = true } label: { Image(systemName: "folder.badge.plus") }.disabled(!store.hasBucket).help("新建文件夹")
            Menu {
                Button("重命名…") { beginRename() }.disabled(store.selectedEntries.count != 1 || !store.hasBucket)
                Button("复制对象路径") { store.copyPath(store.selectedEntries.first) }.disabled(store.selectedEntries.count != 1)
                Button("分享下载…") { if let e = store.selectedEntries.first { store.shareDownload(e) } }.disabled(store.selectedEntries.count != 1 || store.selectedEntries.first?.isDirectory != false)
                Divider()
                Button("删除…", role: .destructive, action: store.deleteSelection).disabled(!store.hasBucket || store.selectedEntries.isEmpty)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            Spacer(minLength: 5)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(store.recursive ? "搜索当前目录及子目录" : "搜索当前目录全部文件", text: $store.query).textFieldStyle(.plain).frame(minWidth: 100, idealWidth: 170, maxWidth: 210)
                    .onChange(of: store.query) { _, _ in store.scheduleSearch() }
                if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary) }
            }.padding(7).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Toggle("子目录", isOn: $store.recursive).toggleStyle(.checkbox).font(.system(size: 11)).disabled(!store.hasBucket)
                .onChange(of: store.recursive) { _, _ in store.reload() }.help("按页搜索子目录；匹配较少时会继续查询后续页，可随时停止")
            Menu {
                Picker("本页排序", selection: $store.sortField) { Text("名称").tag("名称"); Text("大小").tag("大小"); Text("修改时间").tag("修改时间") }
                Toggle("降序", isOn: $store.descending)
            } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).frame(width: 20).help("对本页结果排序；云端按对象名称分页")
        }.controlSize(.regular).font(.system(size: 12)).padding(.horizontal, 22).padding(.bottom, 13)
    }
    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                sortHeader("名称", field: "名称").frame(maxWidth: .infinity, alignment: .leading)
                sortHeader("大小", field: "大小").frame(width: 85, alignment: .trailing)
                sortHeader("修改时间", field: "修改时间").frame(width: 140, alignment: .leading)
                Text("类型").frame(width: 75, alignment: .leading)
                Text("操作").frame(width: 58, alignment: .center)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 35).background(Color.primary.opacity(0.025))
            if store.isLoading, !store.query.isEmpty {
                HStack { ProgressView().controlSize(.mini); Text("正在搜索后续文件，已检查 \(store.scannedEntries) 项；找到的结果会逐步显示"); Spacer() }
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 8)
            }
            if let error = store.listError, !store.entries.isEmpty {
                HStack { Text(error).lineLimit(2); Spacer(); Button("重试", action: store.retryListing) }
                    .font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 24).padding(.vertical, 8)
            }
            if let error = store.listError, store.entries.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.icloud").font(.system(size: 34)).foregroundStyle(.orange)
                    Text("无法读取此位置").font(.headline)
                    ScrollView { Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: 550) }.frame(maxHeight: 130)
                    Button("重试", action: store.retryListing)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else if store.visibleEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: store.isLoading ? "icloud" : "folder").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(store.isLoading ? "正在读取云端文件…" : store.fileHasNext ? "本页没有可显示的文件" : (store.query.isEmpty ? "这里还没有文件" : "没有匹配的文件")).font(.system(size: 14, weight: .medium))
                    Text(store.isLoading ? "每次只读取一页；搜索可随时停止" : store.fileHasNext ? "这一页没有文件，可继续查看下一页" : (store.hasBucket ? "把文件或文件夹拖到这里上传" : "也可以在连接设置中指定有权访问的存储桶"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selected) {
                    ForEach(store.visibleEntries) { entry in
                        fileRow(entry).tag(entry.id).listRowSeparator(.visible)
                            .contextMenu {
                                Button(entry.isDirectory ? "打开" : "预览") { store.open(entry) }
                                if !entry.isDirectory { Button("查看详情") { store.selected = [entry.id]; store.showInspector = true } }
                                if store.hasBucket {
                                    Button("下载…") { if !store.selected.contains(entry.id) { store.selected = [entry.id] }; store.downloadSelection() }
                                    Button("重命名…") { store.selected = [entry.id]; beginRename() }
                                    Button("复制对象路径") { store.copyPath(entry) }
                                    if !entry.isDirectory { Button("分享下载…") { store.shareDownload(entry) } }
                                    Divider()
                                    Button("删除…", role: .destructive) { if !store.selected.contains(entry.id) { store.selected = [entry.id] }; store.deleteSelection() }
                                }
                            }
                    }
                }.listStyle(.inset).alternatingRowBackgrounds(.enabled).id(store.filePage)
            }
            Divider()
            PaginationBar(page: store.filePage, count: store.visibleEntries.count, hasNext: store.fileHasNext, loading: store.isLoading,
                          pageSize: $store.filePageSize, previous: store.previousFilePage, next: store.nextFilePage)
                .onChange(of: store.filePageSize) { _, _ in store.reload() }
            Text("排序仅作用于本页；搜索会查询当前目录的后续页。翻页会清除选择。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 8)
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private func sortHeader(_ name: String, field: String) -> some View {
        Button { if store.sortField == field { store.descending.toggle() } else { store.sortField = field; store.descending = false } } label: {
            HStack(spacing: 4) { Text(name); if store.sortField == field { Image(systemName: store.descending ? "chevron.down" : "chevron.up").font(.system(size: 7)) } }
        }.buttonStyle(.plain).help("按\(name)对本页排序")
    }
    private func fileRow(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(entry)).font(.system(size: 19)).foregroundStyle(entry.isDirectory ? teal : .secondary).frame(width: 23)
            Text(store.recursive ? entry.path : entry.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isDirectory ? "—" : sizeString(entry.size)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
            Text(entry.date.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()) } ?? "—")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(entry.isDirectory ? (store.hasBucket ? "文件夹" : "存储桶") : URL(fileURLWithPath: entry.name).pathExtension.uppercased())
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 75, alignment: .leading)
            if store.hasBucket, let c = store.connection, let loc = store.location {
                HStack(spacing: 10) {
                    if !entry.isDirectory {
                        Button { store.open(entry) } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("预览（也可双击文件）").frame(width: 18)
                    } else { Color.clear.frame(width: 18) }
                    PromiseDragHandle(entry: entry, connection: c, location: loc, store: store).frame(width: 18, height: 22).help("从这里拖到 Finder 下载")
                }.frame(width: 58)
            } else { Color.clear.frame(width: 58) }
        }.frame(height: 35).contentShape(Rectangle()).onTapGesture(count: 2) { store.open(entry) }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("详细信息").font(.system(size: 12, weight: .semibold)); Spacer(); Button { store.showInspector = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            if let entry = store.selectedEntries.first {
                Image(systemName: icon(entry)).font(.system(size: 46, weight: .light)).foregroundStyle(teal).frame(maxWidth: .infinity).padding(.top, 15)
                Text(entry.name).font(.headline).textSelection(.enabled)
                detail("类型", entry.isDirectory ? "文件夹" : "对象文件")
                detail("大小", entry.isDirectory ? "—" : sizeString(entry.size))
                detail("路径", ObjectPath.join(store.location?.prefix ?? "", entry.path))
                detail("修改时间", entry.date?.formatted() ?? "—")
                Button("复制对象路径") { store.copyPath(entry) }
                if store.hasBucket { Button("下载…", action: store.downloadSelection).buttonStyle(.borderedProminent) }
                Text("可从文件行右侧的拖动图标拖到 Finder 下载。").font(.system(size: 11)).foregroundStyle(.secondary)
            } else { Text("选择一个文件以查看信息").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 30) }
            Spacer()
        }.padding(20)
    }
    private func detail(_ name: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 5) { Text(name).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 11)).textSelection(.enabled) } }
    private var statusbar: some View {
        HStack(spacing: 8) {
            Circle().fill(store.listError == nil ? teal : .orange).frame(width: 5, height: 5)
            Text(store.notice ?? (store.showAudit ? "\(store.auditCount) 条操作审计 · 保存在本机" : store.connection == nil ? "准备就绪" : "本页 \(store.visibleEntries.count) 项 · 已选择 \(store.selectedEntries.count) 项"))
                .lineLimit(1)
            Spacer()
            if store.hasBucket && !store.showAudit { Text("同名文件：上传 / 下载前询问").foregroundStyle(.secondary) }
            Text("CloudDock 0.5.7 · Apple Silicon").foregroundStyle(.tertiary)
        }.font(.system(size: 10)).padding(.horizontal, 20).frame(height: 29)
            .onChange(of: store.notice) { _, value in
                guard value != nil else { return }
                Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if store.notice == value { store.notice = nil } }
            }
    }
    private func beginRename() { guard let entry = store.selectedEntries.first else { return }; renameTarget = entry; fieldValue = entry.name; renamePrompt = true }
    private func icon(_ entry: RemoteEntry) -> String {
        if entry.isDirectory { return store.hasBucket ? "folder.fill" : "externaldrive.fill" }
        switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
        case "jpg", "png", "jpeg", "gif", "webp", "svg", "heic": return "photo"
        case "mp4", "mov", "mkv": return "film"
        case "zip", "tar", "gz", "7z": return "doc.zipper"
        case "json", "yaml", "xml", "js", "swift": return "curlybraces.square"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}
