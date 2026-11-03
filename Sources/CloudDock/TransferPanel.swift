import SwiftUI
import AppKit

struct TransferPanel: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.arrow.down.circle.fill").foregroundStyle(.teal)
                Text("传输任务").fontWeight(.semibold)
                Text(store.activeCount == 0 ? "所有任务已就绪" : "\(store.activeCount) 个任务进行中").foregroundStyle(.secondary)
                Spacer()
                Text("最多同时执行 2 个任务").foregroundStyle(.tertiary)
                Button("清除已结束", action: store.clearFinished).buttonStyle(.borderless)
                Button { store.showTransfers = false } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
            }.font(.system(size: 11)).padding(.horizontal, 22).frame(height: 38)
            if store.jobs.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 25, weight: .light)).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("暂无传输任务").font(.system(size: 12))
                        Text("上传和下载的进度、速度与操作记录会显示在这里").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 24).frame(height: 68)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.jobs.reversed()) { job in row(job); Divider().padding(.leading, 56) }
                    }
                }.frame(height: 150)
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
    private func row(_ job: TransferJob) -> some View {
        HStack(spacing: 12) {
            Image(systemName: job.direction == "上传" ? "arrow.up.circle" : job.direction == "下载" ? "arrow.down.circle" : "arrow.triangle.2.circlepath")
                .font(.system(size: 21, weight: .light)).foregroundStyle(job.status == .failed ? .orange : .teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(job.direction) · \(job.connection.name)" + (job.error.map { " · \($0)" } ?? job.resultSummary.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(job.error == nil ? Color.secondary : .orange).lineLimit(1)
                    .help(job.error ?? job.resultSummary ?? "")
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if job.speed > 0 { Text(sizeString(Int64(job.speed)) + "/s").foregroundStyle(.secondary) }
                    Text(job.status.rawValue).foregroundStyle(job.status == .completed ? .teal : [.failed, .skipped, .mixed].contains(job.status) ? .orange : .secondary)
                }.font(.system(size: 10))
                if job.totalBytes > 0 {
                    ProgressView(value: job.status.succeeded ? 1 : min(1, Double(job.bytes) / Double(job.totalBytes))).progressViewStyle(.linear).frame(width: 140)
                } else if job.status == .running { ProgressView().controlSize(.mini) }
            }.frame(width: 155, alignment: .trailing)
            HStack(spacing: 10) {
                if job.status == .running || job.status == .paused {
                    Button { store.pause(job) } label: { Image(systemName: job.status == .paused ? "play.fill" : "pause.fill") }.help(job.status == .paused ? "继续（保持 App 运行）" : "暂停（保持 App 运行）")
                }
                if job.status.active { Button { store.cancel(job) } label: { Image(systemName: "xmark") }.help("取消任务") }
                else if !job.status.succeeded && job.status != .skipped { Button { store.retry(job) } label: { Image(systemName: "arrow.clockwise") }.help("重新尝试") }
                if job.status.succeeded, let path = job.localPath {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                }
                if let error = job.error { Button { store.alert = error } label: { Image(systemName: "info.circle") }.help("错误详情") }
            }.buttonStyle(.borderless).font(.system(size: 11)).frame(width: 65, alignment: .trailing)
        }.padding(.horizontal, 22).frame(height: 56)
    }
}
