import Foundation
import Combine

enum JobKind: String, CaseIterable, Identifiable {
    case compress
    case extract

    var id: String { rawValue }
    var title: String { self == .compress ? "压缩" : "解压" }
    var icon: String { self == .compress ? "archivebox.fill" : "tray.and.arrow.up.fill" }
}

enum JobState: Equatable {
    case queued
    case running
    case done(URL)
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }
}

struct Job: Identifiable {
    let id = UUID()
    var kind: JobKind
    var inputs: [URL]
    var destination: URL
    var format: FormatSpec
    var password: String?
    var level: CompressionLevel = .normal
    var splitSizeMB: Int?
    var makeSubfolder: Bool = false
    var overwrite: OverwritePolicy = .overwrite
    /// 因加密/密码失败，等待用户输入密码后重试
    var needsPassword = false

    // 运行时状态
    var state: JobState = .queued
    var fraction: Double? = nil
    var detail: String = "等待中"
    var startedAt: Date?
    var finishedAt: Date?

    var displayName: String {
        if inputs.count == 1 { return inputs[0].lastPathComponent }
        if inputs.isEmpty { return "（空）" }
        return "\(inputs[0].lastPathComponent) 等 \(inputs.count) 项"
    }

    var outputName: String { destination.lastPathComponent }

    /// 估算剩余时间（秒）
    var eta: TimeInterval? {
        guard let start = startedAt, let f = fraction, f > 0.02, f < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        return max(0, elapsed / f - elapsed)
    }
}

/// 全局任务队列：串行执行，避免多个 zip/tar 争抢磁盘。
@MainActor
final class JobQueue: ObservableObject {

    @Published private(set) var jobs: [Job] = []
    @Published var isProcessing = false
    @Published var concurrency = 2   // 同时运行的任务数

    /// 引擎无状态且线程安全，可从任意上下文访问
    nonisolated(unsafe) private let engine = ArchiveEngine()
    private var runners: [UUID: ProcessRunner] = [:]
    private let queue = DispatchQueue(label: "zipmate.jobs", qos: .userInitiated, attributes: .concurrent)

    var activeCount: Int {
        jobs.filter { $0.state == .running }.count
    }

    var pendingJobs: [Job] {
        jobs.filter { $0.state == .queued }
    }

    // MARK: - 预览支持

    /// 仅供 SwiftUI 预览 / 视觉快照注入演示数据，生产路径不会调用
    func seedForPreview(_ items: [Job]) {
        jobs = items
    }

    // MARK: - 入队

    func enqueueCompress(_ items: [URL], destination: URL, format: FormatSpec,
                         level: CompressionLevel, password: String?, splitSizeMB: Int?) {
        jobs.insert(Job(kind: .compress, inputs: items, destination: destination,
                        format: format, password: password, level: level,
                        splitSizeMB: splitSizeMB), at: 0)
        processQueue()
    }

    func enqueueExtract(_ archives: [URL], destination: URL, makeSubfolder: Bool,
                        overwrite: OverwritePolicy, password: String?,
                        nearArchive: Bool = false) {
        // 每个压缩包一个任务；nearArchive=true 时解到压缩包所在文件夹（打开方式/菜单栏自动解压）
        var newJobs: [Job] = []
        for a in archives {
            let sig = ArchiveProbe.classify(a)
            // 为解压推断一个展示用格式
            let spec = Formats.spec(id: sig.formatID) ?? Formats.zip
            let dest = nearArchive ? a.deletingLastPathComponent() : destination
            newJobs.append(Job(kind: .extract, inputs: [a], destination: dest,
                               format: spec, password: password,
                               makeSubfolder: makeSubfolder, overwrite: overwrite))
        }
        jobs.insert(contentsOf: newJobs, at: 0)
        processQueue()
    }

    func remove(_ job: Job) {
        cancel(job)
        jobs.removeAll { $0.id == job.id }
    }

    /// 只清除「成功完成」的任务，保留失败/已取消以便重试
    func removeFinished() {
        jobs.removeAll { if case .done = $0.state { return true }; return false }
    }

    /// 完成后保留时长：3 天
    static let retentionInterval: TimeInterval = 3 * 24 * 3600

    /// 清理完成/失败/取消超过 3 天的终态任务
    func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)
        jobs.removeAll { job in
            guard job.state.isTerminal, let t = job.finishedAt else { return false }
            return t < cutoff
        }
    }

    func clearAll() {
        runners.values.forEach { $0.cancel() }
        runners.removeAll()
        jobs.removeAll()
        isProcessing = false
    }

    func retry(_ job: Job, password: String? = nil) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        if let pw = password, !pw.isEmpty { jobs[idx].password = pw }
        jobs[idx].needsPassword = false
        jobs[idx].state = .queued
        jobs[idx].fraction = nil
        jobs[idx].detail = "等待中"
        jobs[idx].finishedAt = nil
        processQueue()
    }

    func cancel(_ job: Job) {
        if let r = runners[job.id] {
            r.cancel()
        }
        update(job.id) { j in
            if !j.state.isTerminal {
                j.state = .cancelled
                j.detail = "已取消"
                j.finishedAt = Date()
            }
        }
    }

    func cancelAll() {
        jobs.filter { !$0.state.isTerminal }.forEach { cancel($0) }
    }

    // MARK: - 调度

    private func processQueue() {
        guard !isProcessing else { return }
        isProcessing = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                guard let job = self.jobs.first(where: { $0.state == .queued }) else { break }

                self.update(job.id) { j in
                    j.state = .running
                    j.startedAt = Date()
                    j.detail = "准备中…"
                }
                let runner = ProcessRunner()
                self.runners[job.id] = runner
                let snapshot = job
                self.start(snapshot, runner: runner)

                // 等待该任务结束
                while let cur = self.jobs.first(where: { $0.id == snapshot.id }),
                      !cur.state.isTerminal {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                self.runners[snapshot.id] = nil
            }
            self.isProcessing = false
        }
    }

    private func start(_ job: Job, runner: ProcessRunner) {
        queue.async { [weak self] in
            guard let self else { return }
            // 进度回调 → 主线程
            let report: (ProgressUpdate) -> Void = { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    self.update(job.id) { j in
                        if let f = p.fraction { j.fraction = f }
                        if !p.currentItem.isEmpty { j.detail = p.currentItem }
                    }
                }
            }

            do {
                switch job.kind {
                case .compress:
                    let opts = ArchiveEngine.CompressOptions(
                        format: job.format, level: job.level,
                        password: job.password, splitSizeMB: job.splitSizeMB)
                    let out = try self.engine.compress(
                        inputs: job.inputs, to: job.destination,
                        options: opts, runner: runner, progress: report)
                    Task { @MainActor in
                        self.update(job.id) { j in
                            j.state = .done(out)
                            j.destination = out
                            j.fraction = 1
                            j.detail = self.summarize(original: job, output: out)
                            j.finishedAt = Date()
                        }
                    }

                case .extract:
                    let opts = ArchiveEngine.ExtractOptions(
                        password: job.password, overwrite: job.overwrite,
                        makeSubfolder: job.makeSubfolder)
                    let dir = try self.engine.extract(
                        archive: job.inputs[0], to: job.destination,
                        options: opts, runner: runner, progress: report)
                    Task { @MainActor in
                        self.update(job.id) { j in
                            j.state = .done(dir)
                            j.fraction = 1
                            j.detail = "已解压到 \(dir.lastPathComponent)"
                            j.finishedAt = Date()
                        }
                    }
                }
            } catch let e as ProcessError where e == .cancelled {
                Task { @MainActor in
                    self.update(job.id) { j in
                        if !j.state.isTerminal {
                            j.state = .cancelled
                            j.detail = "已取消"
                            j.finishedAt = Date()
                        }
                    }
                }
            } catch EngineError.badPassword {
                Task { @MainActor in
                    self.update(job.id) { j in
                        j.needsPassword = true
                        j.state = .failed("需要密码")
                        j.detail = "压缩包已加密，请输入密码后解锁"
                        j.finishedAt = Date()
                    }
                }
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in
                    self.update(job.id) { j in
                        j.state = .failed(msg)
                        j.detail = msg
                        j.finishedAt = Date()
                    }
                }
            }
        }
    }

    private nonisolated func summarize(original: Job, output: URL) -> String {
        let outSize = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let (_, inBytes) = ArchiveEngine.measure(original.inputs)
        if inBytes > 0 {
            let ratio = Double(outSize) / Double(inBytes) * 100
            let saved = inBytes > outSize
                ? "节省 \(Self.fmt(inBytes - outSize))"
                : "增大 \(Self.fmt(outSize - inBytes))"
            return "\(Self.fmt(outSize)) · 压缩率 \(String(format: "%.1f", ratio))% · \(saved)"
        }
        return Self.fmt(outSize)
    }

    nonisolated static func fmt(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private func update(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[idx])
        jobs = jobs   // 触发刷新
    }
}

extension ProcessError: Equatable {
    static func == (a: ProcessError, b: ProcessError) -> Bool {
        switch (a, b) {
        case (.cancelled, .cancelled): return true
        default: return false
        }
    }
}
