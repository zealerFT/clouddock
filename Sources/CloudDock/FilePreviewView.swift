import SwiftUI
import AppKit
import PDFKit
import ImageIO
import CloudDockCore

struct PreviewRequest: Identifiable {
    let id = UUID()
    let entry: RemoteEntry
    let connection: Connection
    let location: Location
}

struct FilePreviewView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let request: PreviewRequest
    @State private var loading = true
    @State private var message: String?
    @State private var text: String?
    @State private var picture: NSImage?
    @State private var document: PDFDocument?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 23)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.entry.name).font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text("\(request.connection.name) · \(sizeString(request.entry.size))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.downloadPreview(request) } label: { Label("下载…", systemImage: "arrow.down") }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            Group {
                if loading {
                    VStack(spacing: 12) { ProgressView(); Text("正在加载预览…").font(.system(size: 12)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.questionmark").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                        Text("无法预览此文件").font(.headline)
                        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
                        Button("下载后查看") { store.downloadPreview(request) }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                } else if let text { PlainTextPreview(text: text) }
                else if let picture { Image(nsImage: picture).resizable().scaledToFit().padding(20).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let document { PDFPreview(document: document) }
            }.background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack {
                Text("只读预览 · 文本 ≤ 1 MB · 图片 / PDF ≤ 10 MB").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if text != nil { Text("HTML、Markdown 和脚本以纯文本显示").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 20).frame(height: 30)
        }.frame(width: 860, height: 620)
            .task(id: request.id) { await load() }
    }
    @MainActor private func load() async {
        do {
            // Reject unsupported/large objects before reading credentials or the network.
            _ = try PreviewPolicy.kind(name: request.entry.name, size: request.entry.size)
            let content = try await store.engine.preview(connection: request.connection, credentials: store.credentialStore.read(for: request.connection), bucket: request.location.bucket,
                                                         key: ObjectPath.join(request.location.prefix, request.entry.path), name: request.entry.name, size: request.entry.size)
            guard !Task.isCancelled else { return }
            switch content.kind {
            case .text: text = try PreviewPolicy.decodeText(content.data)
            case .image:
                guard let source = CGImageSourceCreateWithData(content.data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                                                                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                    throw CloudError.message("图片格式无法解析或文件已损坏。")
                }
                picture = NSImage(cgImage: image, size: .zero)
            case .pdf:
                guard let pdf = PDFDocument(data: content.data), !pdf.isLocked else { throw CloudError.message("无法预览加密或损坏的 PDF。") }
                guard pdf.pageCount <= 200 else { throw CloudError.message("PDF 超过 200 页，请下载后查看。") }
                document = pdf
            }
        } catch {
            guard !Task.isCancelled else { return }
            message = error.localizedDescription
        }
        loading = false
    }
}

private struct PlainTextPreview: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        let view = NSTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 18, height: 18)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}
