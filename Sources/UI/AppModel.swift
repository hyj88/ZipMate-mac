import SwiftUI
import AppKit

/// 应用状态：当前模式、已选文件、各类选项
@MainActor
final class AppModel: ObservableObject {
    @Published var mode: WorkMode = .extract

    // 压缩
    @Published var items: [URL] = []
    @Published var formatID: String = Formats.zip.id
    @Published var level: CompressionLevel = .normal
    @Published var password: String = ""
    @Published var usePassword = false
    @Published var outputName: String = ""
    @Published var outputDir: URL = defaultOutputDir
    @Published var splitEnabled = false
    @Published var splitMB: Int = 100

    // 解压
    @Published var archives: [URL] = []
    @Published var extractDir: URL = defaultExtractDir
    @Published var makeSubfolder = true
    @Published var overwrite: OverwritePolicy = .overwrite

    private static var defaultOutputDir: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    private static var defaultExtractDir: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    private weak var queue: JobQueue?

    func wire(queue: JobQueue) { self.queue = queue }

    // MARK: - 派生

    var selectedFormat: FormatSpec { Formats.spec(id: formatID) ?? Formats.zip }

    var outputURL: URL {
        let stem = outputName.isEmpty
            ? (items.first?.deletingPathExtension().lastPathComponent ?? "Archive")
            : outputName
        return outputDir.appendingPathComponent(stem + selectedFormat.ext)
    }

    var totalEntries: Int { ArchiveEngine.measure(items).entries }
    var totalBytes: Int64 { ArchiveEngine.measure(items).bytes }

    var canSubmit: Bool {
        switch mode {
        case .compress:
            guard !items.isEmpty else { return false }
            if selectedFormat.kind == .stream && items.count != 1 { return false }
            if usePassword && !selectedFormat.supportsPassword { return false }
            return true
        case .extract:
            return !archives.isEmpty
        }
    }

    var blockingReason: String? {
        switch mode {
        case .compress:
            if items.isEmpty { return "请先添加要压缩的文件" }
            if selectedFormat.kind == .stream && items.count != 1 {
                return "\(selectedFormat.displayName) 只能压缩单个文件"
            }
            if usePassword && !selectedFormat.supportsPassword {
                return "\(selectedFormat.displayName) 不支持密码"
            }
            return nil
        case .extract:
            return archives.isEmpty ? "请先添加压缩包" : nil
        }
    }

    func validate(queue: JobQueue) {
        if usePassword && !selectedFormat.supportsPassword { usePassword = false }
        if splitEnabled && !selectedFormat.supportsSplit { splitEnabled = false }
        syncOutputName()
    }

    func syncOutputName() {
        guard let first = items.first else { outputName = ""; return }
        if outputName.isEmpty { outputName = first.deletingPathExtension().lastPathComponent }
    }

    // MARK: - 分流：压缩包 vs 普通文件

    /// 依据当前模式自动把拖入内容分到对应列表
    func addItems(_ urls: [URL], queue: JobQueue) {
        let archivesIn = urls.filter { ArchiveProbe.looksLikeArchive($0) }

        switch mode {
        case .compress:
            // 压缩页接收一切（文件、文件夹、甚至现成压缩包），只去重，不做分流丢弃
            for u in urls where !items.contains(u) { items.append(u) }
            syncOutputName()
        case .extract:
            for u in archivesIn where !archives.contains(u) { archives.append(u) }
        }
    }

    // MARK: - 提交

    /// 提交幂等：10 秒内同一批输入不重复入队，防止「打开方式」多窗口重复触发解压/压缩
    private var lastSubmitKey: String?
    private var lastSubmitAt: Date?

    /// extractNearArchive=true：自动解压时解到压缩包所在文件夹，而非界面默认的下载目录
    func submit(queue: JobQueue, extractNearArchive: Bool = false) {
        guard canSubmit else { return }
        let key: String
        switch mode {
        case .compress: key = items.map(\.path).joined(separator: "|")
        case .extract: key = archives.map(\.path).joined(separator: "|")
        }
        if let t = lastSubmitAt, lastSubmitKey == key,
           Date().timeIntervalSince(t) < 10 { return }
        lastSubmitKey = key
        lastSubmitAt = Date()
        switch mode {
        case .compress:
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            queue.enqueueCompress(
                items,
                destination: outputURL,
                format: selectedFormat,
                level: level,
                password: usePassword && !password.isEmpty ? password : nil,
                splitSizeMB: splitEnabled ? splitMB : nil
            )
        case .extract:
            // 自动解压（打开方式/菜单栏）默认解到压缩包所在地，界面目录同步显示首包所在文件夹
            if extractNearArchive, let home = archives.first?.deletingLastPathComponent() {
                extractDir = home
            }
            try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            queue.enqueueExtract(
                archives,
                destination: extractDir,
                makeSubfolder: makeSubfolder,
                overwrite: overwrite,
                password: nil,
                nearArchive: extractNearArchive
            )
        }
    }
}
