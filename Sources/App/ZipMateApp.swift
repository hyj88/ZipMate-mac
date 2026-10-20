import SwiftUI
import AppKit

@main
struct ZipMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开主窗口") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("操作") {
                Button("压缩 Finder 选中项") {
                    delegate.compressFinderSelection()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("解压剪贴板中的压缩包") {
                    delegate.extractFromPasteboard()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button("取消全部任务") {
                    NotificationCenter.default.post(name: .zipmateCancelAll, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

// MARK: - 应用代理：菜单栏 + Finder 集成

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let queue = JobQueueBridge.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 普通应用：不驻留菜单栏，关窗即退出
        setupFileHandling()

        // 强制单窗口：窗口成为焦点或显示时收敛，只保留最前一个，关闭多余重复窗
        for note in [NSWindow.didBecomeKeyNotification, NSWindow.didExposeNotification] {
            NotificationCenter.default.addObserver(
                forName: note, object: nil, queue: .main
            ) { [weak self] _ in self?.reconcileWindows() }
        }

        // 视图就绪后补发冷启动期间缓存的打开文件
        NotificationCenter.default.addObserver(
            forName: .zipmateViewReady, object: nil, queue: .main
        ) { [weak self] _ in self?.onViewReady() }

        // 冷启动时 onAppear/viewReady 可能早于本监听注册，导致补发错过；
        // 注册后在下一主循环周期主动标记就绪并补发（此时视图通常已挂载、Router 已订阅）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readyToRoute = true
            self.deliverPending()
        }

        // 处理命令行传入的文件（双击关联）
        if CommandLine.arguments.count > 1 {
            let urls = CommandLine.arguments.dropFirst()
                .filter { !$0.hasPrefix("-") }
                .map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.handleIncoming(urls)
                }
            }
        }
    }

    /// 冷启动时视图尚未挂载、路由通知还没订阅，先缓存，就绪后补发
    private var pendingOpen: [URL] = []
    private var readyToRoute = false

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpen.append(contentsOf: urls)
        deliverPending()
    }

    /// 单文件打开兜底（部分场景系统只回调 openFile:）
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        application(sender, open: [URL(fileURLWithPath: filename)])
        return true
    }

    /// 视图就绪后调用，补发启动前缓存的打开文件
    func onViewReady() {
        readyToRoute = true
        deliverPending()
    }

    private func deliverPending() {
        guard readyToRoute, !pendingOpen.isEmpty else { return }
        let urls = pendingOpen
        pendingOpen.removeAll()
        handleIncoming(urls)
    }

    /// 收敛到单个主窗口：关闭多余的重复标准窗口，只保留最前（z-order 最高）的一个
    private func reconcileWindows() {
        let std = NSApp.windows.filter {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil
        }
        guard std.count > 1, let keep = std.last else { return }
        for w in std where w !== keep { w.close() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true   // 普通应用：关掉最后一个窗口即退出，不驻留
    }

    // MARK: 菜单栏

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "ZipMate")
        item.button?.toolTip = "ZipMate 压缩工具"

        let menu = NSMenu()

        menu.addItem(withTitle: "打开主窗口", action: #selector(openMainWindow), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        let comp = NSMenuItem(title: "压缩 Finder 选中项…", action: #selector(compressFinderSelection), keyEquivalent: "")
        comp.target = self
        menu.addItem(comp)

        menu.addItem(.separator())

        // 快速格式子菜单
        let formatMenu = NSMenu(title: "快速压缩格式")
        for spec in Formats.archivable.prefix(5) {
            let it = NSMenuItem(title: spec.displayName, action: #selector(quickCompress(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = spec.id
            formatMenu.addItem(it)
        }
        let fmtItem = NSMenuItem(title: "格式", action: nil, keyEquivalent: "")
        fmtItem.submenu = formatMenu
        menu.addItem(fmtItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ZipMate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first {
            w.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("newDocument:")), to: nil, from: nil)
        }
    }

    @objc private func quickCompress(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let spec = Formats.spec(id: id) else { return }
        let selection = finderSelection()
        guard !selection.isEmpty else {
            presentNoSelectionAlert()
            return
        }
        self.pendingFormatOverride = spec
        routeToMainWindow(files: selection, mode: .compress)
    }

    private var pendingFormatOverride: FormatSpec?

    @objc func compressFinderSelection() {
        let selection = finderSelection()
        guard !selection.isEmpty else {
            presentNoSelectionAlert()
            return
        }
        routeToMainWindow(files: selection, mode: .compress)
    }

    func extractFromPasteboard() {
        let pb = NSPasteboard.general
        let urls: [URL] = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let archives = urls.filter { ArchiveProbe.looksLikeArchive($0) }
        guard !archives.isEmpty else { return }
        routeToMainWindow(files: archives, mode: .extract)
    }

    // MARK: Finder 交互

    private func finderSelection() -> [URL] {
        let script = NSAppleScript(source: """
        tell application "Finder"
            set theItems to selection
            set out to {}
            repeat with i in theItems
                set end of out to POSIX path of (i as alias)
            end repeat
            return out as string
        end tell
        """)
        var err: NSDictionary?
        guard let result = script?.executeAndReturnError(&err),
              err == nil else { return [] }
        let raw = result.stringValue ?? ""
        return raw.split(separator: ",").map {
            URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func presentNoSelectionAlert() {
        let alert = NSAlert()
        alert.messageText = "Finder 中没有选中文件"
        alert.informativeText = "请先在 Finder 中选中要压缩的文件或文件夹。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func routeToMainWindow(files: [URL], mode: WorkMode) {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow()
        reconcileWindows()
        // 新窗异步建立后再收敛一次，避免「打开方式」额外开一个重复窗
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reconcileWindows()
        }
        NotificationCenter.default.post(name: .zipmateRouteFiles, object: files,
                                        userInfo: ["mode": mode])
    }

    // 进程级去重：同一批文件 10 秒内只处理一次，挡住多窗口/重复回调导致的重复入队
    private static var lastHandledKey: String?
    private static var lastHandledTime: Date?

    private func handleIncoming(_ urls: [URL]) {
        let key = urls.map { $0.path }.sorted().joined(separator: "|")
        let now = Date()
        if let t = Self.lastHandledTime, Self.lastHandledKey == key,
           now.timeIntervalSince(t) < 10 { return }
        Self.lastHandledKey = key
        Self.lastHandledTime = now

        let archives = urls.filter { ArchiveProbe.looksLikeArchive($0) }
        let others = urls.filter { !ArchiveProbe.looksLikeArchive($0) }
        if !others.isEmpty {
            routeToMainWindow(files: others, mode: .compress)
        } else if !archives.isEmpty {
            routeToMainWindow(files: archives, mode: .extract)
        }
    }

    // MARK: 文件关联

    private func setupFileHandling() {
        AppShortcut.shared.ensureServicesInstalled()
    }
}

// MARK: - 跨窗口消息桥（菜单栏 → 主窗口）

@MainActor
final class JobQueueBridge {
    static let shared = JobQueueBridge()
    var lastKnownQueue: JobQueue?
}

// MARK: - Finder「服务」菜单注册

final class AppShortcut {
    static let shared = AppShortcut()

    /// 把 ZipMate 注册进 Finder 的「服务」右键菜单
    func ensureServicesInstalled() {
        // 服务菜单依赖 app bundle 内的 Contents/Services 目录，由 Tools/make_services.sh 生成。
        // 若目录缺失则跳过（不影响主功能与菜单栏）。
        let services = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Services")
        if !FileManager.default.fileExists(atPath: services.path) {
            NSLog("[ZipMate] Finder 服务菜单未安装（缺少 Contents/Services），可在构建时运行 make_services.sh 生成")
        }
        NSApp.servicesMenu = NSMenu(title: "ZipMate")
    }
}
