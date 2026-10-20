import SwiftUI

extension Notification.Name {
    static let zipmateRouteFiles = Notification.Name("ZipMateRouteFiles")
    static let zipmateCancelAll = Notification.Name("ZipMateCancelAll")
    static let zipmateViewReady = Notification.Name("ZipMateViewReady")
}

/// 监听来自菜单栏 / Finder 的路由消息，把文件送进当前界面
struct DropRouter: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: JobQueue

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .zipmateRouteFiles)) { note in
                guard let urls = note.object as? [URL], !urls.isEmpty else { return }
                if let raw = note.userInfo?["mode"] as? String,
                   let m = WorkMode(rawValue: raw) {
                    model.mode = m
                }
                model.addItems(urls, queue: queue)
                // 打开方式/菜单栏带入后自动解压：解到压缩包所在文件夹
                if model.canSubmit { model.submit(queue: queue, extractNearArchive: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .zipmateCancelAll)) { _ in
                queue.cancelAll()
            }
    }
}

extension View {
    func dropRouter(model: AppModel, queue: JobQueue) -> some View {
        modifier(DropRouter(model: model, queue: queue))
    }
}
