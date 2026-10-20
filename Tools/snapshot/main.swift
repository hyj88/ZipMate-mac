import SwiftUI
import AppKit

/// 离屏快照用演示数据（不属于生产路径，仅 Tools/snapshot 使用）

@MainActor
func makeDemo(mode: WorkMode) -> (AppModel, JobQueue) {
    let m = AppModel()
    m.mode = mode
    let q = JobQueue()
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("zm-demo-\(UUID().uuidString.prefix(4))")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    func mk(_ name: String, _ size: Int, isDir: Bool = false) -> URL {
        let u = tmp.appendingPathComponent(name)
        if isDir {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        } else {
            try? Data(count: min(size, 2_000_000)).write(to: u)
        }
        return u
    }

    switch mode {
    case .compress:
        m.items = [
            mk("项目文档.pdf", 2_400_000),
            mk("设计稿 v3.sketch", 1_800_000),
            mk("产品演示.mp4", 2_000_000),
            mk("接口配置.json", 8_200),
            mk("素材归档", 0, isDir: true),
        ]
        m.outputName = "2026Q4 项目归档"
        m.usePassword = true
        m.password = "secret"
        m.formatID = Formats.zip.id
        m.level = .high
        q.seedForPreview([
            Job(kind: .compress, inputs: [m.items[0]],
                destination: tmp.appendingPathComponent("a.zip"),
                format: Formats.zip, password: nil, level: .high,
                state: .done(tmp), fraction: 1,
                detail: "2.3 MB · 压缩率 61.2% · 节省 3.6 MB",
                startedAt: Date().addingTimeInterval(-8), finishedAt: Date()),
            Job(kind: .compress, inputs: [m.items[2]],
                destination: tmp.appendingPathComponent("b.zip"),
                format: Formats.zip, password: nil, level: .normal,
                state: .running, fraction: 0.62, detail: "产品演示.mp4",
                startedAt: Date().addingTimeInterval(-3)),
            Job(kind: .compress, inputs: [m.items[4]],
                destination: tmp.appendingPathComponent("c.tar.gz"),
                format: Formats.tarGz, password: nil,
                state: .failed("tar: 磁盘空间不足"), fraction: 0.34,
                detail: "tar: 磁盘空间不足",
                startedAt: Date().addingTimeInterval(-20), finishedAt: Date()),
        ])
    case .extract:
        m.archives = [
            mk("项目交付.rar", 1_400_000),
            mk("源码备份.tar.gz", 900_000),
            mk("设计导出.zip", 600_000),
        ]
        m.extractDir = mk("解压结果", 0, isDir: true)
        m.makeSubfolder = true
        m.overwrite = .overwrite
        q.seedForPreview([
            Job(kind: .extract, inputs: [m.archives[0]], destination: tmp,
                format: Formats.rar, password: nil,
                state: .done(tmp), fraction: 1, detail: "已解压到 解压结果",
                startedAt: Date().addingTimeInterval(-5), finishedAt: Date()),
            Job(kind: .extract, inputs: [m.archives[1]], destination: tmp,
                format: Formats.tarGz, password: nil,
                state: .running, fraction: nil, detail: "源码备份.tar.gz/src/",
                startedAt: Date().addingTimeInterval(-1)),
        ])
    }
    return (m, q)
}

@MainActor
func run() {
    let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Screenshots"
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let size = CGSize(width: 1180, height: 720)
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.accessory)

    for (name, mode) in [("compress", WorkMode.compress), ("extract", WorkMode.extract)] {
        let (m, q) = makeDemo(mode: mode)
        let path = "\(out)/\(name).png"
        if Snapshotter.save(PreviewShell(model: m, queue: q), to: path, size: size, scale: 2) {
            print("saved \(path)")
        } else {
            print("FAILED \(name)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    exit(0)
}

MainActor.assumeIsolated { run() }
