import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloudDockCore

@MainActor
struct ShareDownloadView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let request: ShareRequest
    @State private var preset = 3600
    @State private var customAmount = "2"
    @State private var unit: ShareTimeUnit = .hours
    @State private var share: DownloadShare?
    @State private var qrPNG: Data?
    @State private var qrImage: NSImage?
    @State private var qrError: String?
    @State private var error: String?
    @State private var feedback: String?
    @State private var generating = false
    @State private var generation: Task<Void, Never>?

    private var isLocalEmulator: Bool { request.connection.isLocalGoogleEndpoint }
    private var seconds: Int? {
        if isLocalEmulator { return 3600 }
        if preset != 0 { return preset }
        guard let amount = Int(customAmount.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? SharePolicy.duration(amount: amount, unit: unit)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let expired = share?.expiresAt.map { $0 <= timeline.date } ?? false
            VStack(spacing: 0) {
                header
                Divider()
                VStack(alignment: .leading, spacing: 20) {
                    if isLocalEmulator {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("本地测试服务 · 无自动过期", systemImage: "info.circle").font(.system(size: 13, weight: .medium))
                            Text("fake-gcs-server 不校验签名与有效期，生成的是直接下载地址；删除文件后地址失效。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else { expirationControls }
                    HStack(alignment: .top, spacing: 24) {
                        addressPanel(expired: expired).frame(maxWidth: .infinity, alignment: .leading)
                        qrPanel(expired: expired).frame(width: 270)
                    }.frame(maxHeight: .infinity, alignment: .top)
                    if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.system(size: 12)).textSelection(.enabled) }
                    if let feedback { Label(feedback, systemImage: "checkmark.circle.fill").foregroundStyle(.teal).font(.system(size: 12)) }
                    Text(isLocalEmulator
                         ? "接收方需能访问该服务。localhost / 127.0.0.1 仅本机可用，手机扫码无法访问电脑的本机地址。"
                         : "链接直接访问存储服务，接收方需能访问该地址。临时凭据过期或文件删除时，链接可能提前失效。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(24)
                Divider()
                HStack(spacing: 12) {
                    Text(isLocalEmulator ? "测试服务直链不提供限时访问控制。" : "调整有效期后需重新生成，已发出的旧链接不会自动失效。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if generating { ProgressView().controlSize(.small) }
                    Button(share == nil ? "生成分享链接" : "重新生成") { generate(copyAddress: false) }
                        .disabled(generating || seconds == nil)
                    Button(share == nil || expired ? "生成并复制地址" : "复制分享地址") {
                        if let share, !expired { copyAddress(share.address) }
                        else { generate(copyAddress: true) }
                    }.buttonStyle(.borderedProminent).disabled(generating || seconds == nil)
                }.padding(20)
            }
        }.frame(width: 860, height: 650)
            .onChange(of: preset) { _, _ in invalidate() }
            .onChange(of: customAmount) { _, _ in invalidate() }
            .onChange(of: unit) { _, _ in invalidate() }
            .onDisappear { generation?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 25)).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 5) {
                Text("分享下载").font(.system(size: 19, weight: .semibold))
                Text("\(request.entry.name) · \(request.connection.name) · \(sizeString(request.entry.size))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24)
    }

    private var expirationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("有效期").font(.system(size: 13, weight: .medium))
                Picker("有效期", selection: $preset) {
                    Text("15 分钟").tag(900)
                    Text("1 小时").tag(3600)
                    Text("1 天").tag(86400)
                    Text("7 天").tag(604800)
                    Text("自定义时长").tag(0)
                }.labelsHidden().frame(width: 180).disabled(generating)
                if preset == 0 {
                    TextField("时长", text: $customAmount).textFieldStyle(.roundedBorder).frame(width: 70).disabled(generating)
                    Picker("单位", selection: $unit) { ForEach(ShareTimeUnit.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().frame(width: 85).disabled(generating)
                }
                Spacer()
            }
            Text(seconds == nil ? "请输入整数时长，有效期须在 1 分钟至 7 天之间。" : "从生成时开始计时，支持 1 分钟至 7 天。")
                .font(.system(size: 11)).foregroundStyle(seconds == nil ? .orange : .secondary)
        }
    }

    private func addressPanel(expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("分享地址").font(.system(size: 13, weight: .semibold))
            if let share {
                ScrollView {
                    Text(share.address).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 150).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Label(expired ? "链接已到期，请重新生成" : (qrPNG == nil ? "分享地址已生成" : "链接与二维码已就绪"), systemImage: expired ? "clock.badge.exclamationmark" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(expired ? .orange : .teal)
                if let expiresAt = share.expiresAt {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("到期时间（本地时区）").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(expiresAt.formatted(date: .numeric, time: .standard)).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                    }
                } else {
                    Text("无自动过期 · 本地测试直链").font(.system(size: 13, weight: .medium))
                }
                Text(isLocalEmulator ? "任何能访问此服务的人均可下载此文件。" : "获得地址或二维码的人可在有效期内下载此文件。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "link").font(.system(size: 25)).foregroundStyle(.secondary)
                    Text(generating ? "正在生成下载分享…" : isLocalEmulator ? "生成本地测试下载直链" : "选择有效期后生成下载分享")
                        .font(.system(size: 13, weight: .medium))
                    Text("可以生成地址和二维码，也可以点击“生成并复制地址”一步完成。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 150, alignment: .leading).padding(16)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func qrPanel(expired: Bool) -> some View {
        VStack(spacing: 10) {
            if let qrImage {
                Image(nsImage: qrImage).interpolation(.none).resizable().scaledToFit().frame(width: 250, height: 250)
                    .opacity(expired ? 0.3 : 1).background(.white).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "qrcode").font(.system(size: 60, weight: .light)).foregroundStyle(.secondary)
                    Text(qrError ?? "生成后显示下载二维码").font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(16).frame(width: 250, height: 250).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("复制二维码") { copyQR() }
                Button("保存二维码…") { saveQR() }
            }.font(.system(size: 11)).disabled(qrPNG == nil || expired || generating)
            Text(isLocalEmulator ? "二维码内容与下载直链相同" : "二维码与分享地址的有效期相同").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func invalidate() {
        share = nil; qrPNG = nil; qrImage = nil; qrError = nil; error = nil; feedback = nil
    }

    private func generate(copyAddress: Bool) {
        guard !generating, let seconds else { return }
        invalidate(); generating = true
        generation = Task { @MainActor in
            defer { generating = false }
            do {
                let result = try await store.generateShare(request, seconds: seconds)
                guard !Task.isCancelled else { return }
                share = result
                do {
                    let data = try ShareQRCode.png(address: result.address)
                    qrPNG = data; qrImage = NSImage(data: data)
                } catch { qrError = error.localizedDescription }
                if copyAddress { self.copyAddress(result.address) }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func copyAddress(_ address: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(address, forType: .string) { feedback = "分享地址已复制"; error = nil }
        else { error = "无法写入剪贴板，请选中地址手动复制。" }
    }
    private func copyQR() {
        guard let qrPNG else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setData(qrPNG, forType: .png) { feedback = "二维码图片已复制"; error = nil }
        else { error = "无法写入剪贴板，请保存二维码后分享。" }
    }
    private func saveQR() {
        guard let qrPNG else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = request.entry.name + "-分享二维码.png"
        panel.prompt = "保存二维码"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try qrPNG.write(to: destination, options: .atomic); feedback = "二维码已保存"; error = nil }
        catch { self.error = "保存二维码失败：\(error.localizedDescription)" }
    }
}
