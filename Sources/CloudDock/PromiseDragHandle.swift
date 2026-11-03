import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CloudDockCore

struct PromiseDragHandle: NSViewRepresentable {
    var entry: RemoteEntry
    var connection: Connection
    var location: Location
    var store: AppStore
    func makeNSView(context: Context) -> PromiseView { PromiseView() }
    func updateNSView(_ view: PromiseView, context: Context) {
        view.entry = entry; view.connection = connection; view.location = location; view.store = store
    }
}

final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    let entry: RemoteEntry
    let connection: Connection
    let location: Location
    weak var store: AppStore?
    init(entry: RemoteEntry, connection: Connection, location: Location, store: AppStore?) {
        self.entry = entry; self.connection = connection; self.location = location; self.store = store
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { entry.name }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            guard let store else { completionHandler(CloudError.message("App 已关闭。")); return }
            store.promiseDownload(entry: entry, connection: connection, location: location, destination: url, completion: completionHandler)
        }
    }
}

final class PromiseView: NSView, NSDraggingSource {
    var entry: RemoteEntry?
    var connection: Connection?
    var location: Location?
    weak var store: AppStore?
    // Keep providers and delegates alive until their promises have been fulfilled.
    private var activePromises: [NSFilePromiseProvider] = []
    private var writers: [PromiseWriter] = []
    override func draw(_ dirtyRect: NSRect) {
        NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "拖到 Finder 下载")?.draw(in: bounds.insetBy(dx: 2, dy: 2))
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let entry, let connection, let location else { return }
        let writer = PromiseWriter(entry: entry, connection: connection, location: location, store: store)
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: URL(fileURLWithPath: entry.name).pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: writer)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSImage(systemSymbolName: entry.isDirectory ? "folder.fill" : "doc.fill", accessibilityDescription: entry.name) ?? NSImage(size: NSSize(width: 32, height: 32))
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: icon)
        activePromises.append(provider); writers.append(writer)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .outsideApplication ? .copy : [] }
}
