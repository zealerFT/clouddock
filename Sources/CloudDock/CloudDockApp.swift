import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let store, store.activeCount > 0,
           !store.confirm("仍有 \(store.activeCount) 个传输任务", "退出会中断传输。下次打开可手动重试；不保证从上传中断点恢复。", action: "退出并中断") { return .terminateCancel }
        store?.shutdown()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct CloudDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("CloudDock", id: "main") {
            WorkspaceView().environmentObject(store)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear { delegate.store = store; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1320, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { Button("显示 CloudDock") { NSApp.windows.first?.makeKeyAndOrderFront(nil) }.keyboardShortcut("0") }
            CommandMenu("文件操作") {
                Button("上传文件或文件夹…") { store.chooseUploads() }.keyboardShortcut("u").disabled(!store.hasBucket)
                Button("下载选中项…") { store.downloadSelection() }.keyboardShortcut("d").disabled(store.selectedEntries.isEmpty || !store.hasBucket)
                Divider()
                Button("刷新") { store.reload() }.keyboardShortcut("r")
                Button("收藏当前目录") { store.toggleFavorite() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("返回上级") { store.up() }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("全选") { store.selected = Set(store.visibleEntries.map(\.id)) }.keyboardShortcut("a")
            }
        }
    }
}
