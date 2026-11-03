import SwiftUI

struct PaginationBar: View {
    let page: Int
    let count: Int
    var total: Int? = nil
    let hasNext: Bool
    let loading: Bool
    @Binding var pageSize: Int
    let previous: () -> Void
    let next: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if let total { Text("共 \(total) 项 · 第 \(page + 1) / \(max(1, (total + pageSize - 1) / pageSize)) 页") }
            else { Text("第 \(page + 1) 页 · 本页 \(count) 项" + (hasNext ? " · 还有更多" : "")) }
            Spacer()
            Picker("每页", selection: $pageSize) { ForEach([50, 100, 200], id: \.self) { Text("\($0) 项").tag($0) } }.frame(width: 120).disabled(loading)
            Button("上一页", action: previous).disabled(page == 0 || loading)
            Button("下一页", action: next).disabled(!hasNext || loading)
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 10)
    }
}
