import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloudDockCore

struct ConnectionEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let existing: Connection?
    @State private var draft = Connection()
    @State private var credentials = Credentials()
    @State private var message: String?
    @State private var success = false
    @State private var testing = false
    @State private var checkTask: Task<Void, Never>?
    @State private var loaded = false
    init(existing: Connection?) {
        self.existing = existing
        _draft = State(initialValue: existing ?? Connection())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(existing == nil ? "新建云存储连接" : "编辑连接").font(.system(size: 22, weight: .semibold))
                    Text("保存多个账号，随时在同一个窗口切换。 ").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "externaldrive.badge.icloud").font(.system(size: 32, weight: .light)).foregroundStyle(.teal)
            }.padding(26)
            Divider()
            Form {
                Section {
                    Picker("存储服务", selection: $draft.provider) {
                        ForEach(Provider.newConnectionCases) { p in Text(p.title).tag(p) }
                    }
                        .onChange(of: draft.provider) { _, p in
                            draft.pathStyle = p == .minio || p == .compatible
                            draft.region = p == .aws ? "us-east-1" : ""
                            draft.endpoint = ""; credentials = Credentials(); message = nil
                        }
                    TextField("连接名称", text: $draft.name, prompt: Text("例如：研发 MinIO / 生产 OSS"))
                }
                Section("服务地址") {
                    if draft.provider == .google {
                        TextField("Endpoint（可选）", text: $draft.endpoint,
                                  prompt: Text("留空使用 Google；本地测试填 http://localhost:4443/storage/v1/"))
                        TextField("项目编号（本地填 0）", text: $draft.projectNumber, prompt: Text("真实 Google 的数字 project number；本地填 0"))
                        Text("真实 Google 可留空 Endpoint；fake-gcs-server 本地服务使用 http://localhost:4443/storage/v1/。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if isLocalGoogleEndpoint {
                            Text("本地服务提示：项目编号填 0；bucket 名称请填写在下面的“指定存储桶”中。也可以留空以列出全部 bucket。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("Endpoint", text: $draft.endpoint, prompt: Text(endpointPlaceholder))
                        TextField("Region", text: $draft.region, prompt: Text(draft.provider == .aliyun ? "例如 oss-cn-hangzhou" : "例如 us-east-1"))
                        Toggle("使用 Path-style 地址", isOn: Binding(get: { draft.usesPathStyle }, set: { draft.pathStyle = $0 }))
                            .disabled(draft.requiresPathStyle)
                        if draft.requiresPathStyle {
                            Text("本机或 IP 地址自动使用 Path-style，可连接本地 MinIO 和 LocalStack。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(draft.provider == .aliyun ? "填写区域 Endpoint，不要包含 bucket 前缀。OSS 通常使用 virtual-host 地址（关闭 Path-style）。" : "MinIO 使用 S3 API 端口（常见为 9000），不要填写 Console 端口 9001。AWS 可以留空 Endpoint。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    TextField("指定存储桶（可选）", text: $draft.bucket, prompt: Text("没有列桶权限时可直接进入指定 bucket"))
                }
                Section("凭据保存方式") {
                    Picker("保存位置", selection: $draft.credentialStorage) {
                        Text("软件本机（默认）").tag(CredentialStorage.local)
                        Text("macOS 钥匙串").tag(CredentialStorage.keychain)
                    }
                    Text(draft.credentialStorage == .local
                         ? "加密保存在本机软件数据目录，不调用钥匙串。解密材料也在本机，保护依赖当前 Mac 账户。"
                         : "由 macOS 钥匙串保存。读取或更新凭据时，系统可能请求授权。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let existing {
                        HStack {
                            Text("当前保存位置：\(existing.credentialStorage.title)").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("读取已保存凭据", action: loadStoredCredentials)
                        }
                        Text(existing.credentialStorage == draft.credentialStorage
                             ? "可以读取原凭据或直接填写新凭据。保存方式与服务不变时，全部留空保存会保留原凭据。"
                             : "切换保存位置前，请读取原凭据或在下方重新填写；保存成功后再清理原副本。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Section(draft.provider == .google ? "Google 服务账号" : "访问凭据") {
                    if draft.provider == .google {
                        if isLocalGoogleEndpoint {
                            Label("本地 fake-gcs-server：无需 JSON 密钥", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12)).foregroundStyle(.green)
                            Text("保持服务账号为空即可。CloudDock 会使用本机 Endpoint 的匿名 GCS JSON API。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Label(credentials.serviceAccountJSON.isEmpty ? "尚未选择 JSON 密钥文件" : "已加载服务账号 JSON", systemImage: credentials.serviceAccountJSON.isEmpty ? "doc" : "checkmark.shield")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                                Button("选择 JSON…", action: chooseServiceAccount)
                            }
                            Text("真实 Google Cloud Storage 需要服务账号 JSON；首版不包含 Google 浏览器 OAuth 登录。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("Access Key ID", text: $credentials.accessKey)
                        SecureField("Secret Access Key", text: $credentials.secretKey)
                        SecureField("Session / STS Token（可选）", text: $credentials.sessionToken)
                    }
                }
            }.formStyle(.grouped).disabled(testing)
            if let message {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    ScrollView { Text(message).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70)
                }.foregroundStyle(success ? .green : .orange).padding(.horizontal, 26).padding(.bottom, 14)
            }
            Divider()
            HStack {
                Label("保存至\(draft.credentialStorage.title)", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if testing { ProgressView().controlSize(.small); Button("停止测试") { checkTask?.cancel(); testing = false } }
                else { Button("测试连接", action: test) }
                Button("取消") { checkTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存连接") {
                    normalizeLocalGoogleEndpoint()
                    do { try store.saveConnection(draft, credentials: existing != nil && credentials.isEmpty ? nil : credentials); dismiss() }
                    catch { success = false; message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(testing)
            }.padding(22)
        }.frame(width: 640, height: 780)
            .onAppear {
                guard !loaded else { return }; loaded = true
                // Editing a Keychain connection must not force an authorization prompt before
                // the user can choose local storage and enter replacement credentials.
                if existing?.credentialStorage == .local { loadStoredCredentials() }
            }
            .onDisappear { checkTask?.cancel() }
    }
    private var endpointPlaceholder: String {
        switch draft.provider {
        case .minio: return "https://minio.example.com:9000"
        case .aliyun: return "https://oss-cn-hangzhou.aliyuncs.com"
        case .aws: return "留空以使用 AWS 默认端点"
        case .google: return "留空以使用 Google；本地测试为 http://localhost:4443/storage/v1/"
        default: return "https://s3.example.com"
        }
    }
    private var isLocalGoogleEndpoint: Bool {
        draft.provider == .google && !draft.endpoint.isEmpty && draft.requiresPathStyle
    }
    private func loadStoredCredentials() {
        guard let existing else { return }
        do { credentials = try store.credentialStore.read(for: existing); message = "已读取保存的访问凭据。"; success = true }
        catch { message = error.localizedDescription; success = false }
    }
    private func chooseServiceAccount() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                guard data.count < 1024 * 1024 else { throw CloudError.message("服务账号 JSON 文件超过 1 MB，请检查所选文件。") }
                credentials.serviceAccountJSON = String(decoding: data, as: UTF8.self)
            } catch { message = error.localizedDescription; success = false }
        }
    }
    private func test() {
        normalizeLocalGoogleEndpoint()
        if credentials.isEmpty, let existing, existing.provider == draft.provider, existing.credentialStorage == draft.credentialStorage {
            do { credentials = try store.credentialStore.read(for: existing) }
            catch { success = false; message = error.localizedDescription; return }
        }
        do { try draft.validate(credentials) } catch { success = false; message = error.localizedDescription; return }
        testing = true; message = nil
        let c = draft, secret = credentials
        checkTask = Task {
            do {
                let page = try await store.engine.directoryPage(connection: c, credentials: secret, bucket: c.bucket)
                guard !Task.isCancelled else { return }
                success = true; message = "连接成功，首页已读取 \(page.entries.count) 项。此测试只验证读取权限；上传和删除仍以账号权限为准。"
            } catch {
                guard !Task.isCancelled else { return }
                success = false; message = error.localizedDescription
            }
            testing = false
        }
    }
    private func normalizeLocalGoogleEndpoint() {
        guard draft.isLocalGoogleEndpoint else { return }
        draft.endpoint = draft.googleAPIEndpoint
        // fake-gcs-server uses project number 0. A bucket name accidentally
        // entered in this field should not be persisted as a project number.
        if draft.projectNumber.isEmpty || draft.projectNumber.contains(where: { !$0.isNumber }) {
            draft.projectNumber = "0"
        }
    }
}
