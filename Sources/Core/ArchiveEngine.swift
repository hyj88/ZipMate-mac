import Foundation

/// 进度回调
struct ProgressUpdate {
    var fraction: Double?       // 0...1，已知总量时有值
    var currentItem: String
    var bytesDone: Int64
    var bytesTotal: Int64
}

enum EngineError: LocalizedError {
    case badPassword
    case corruptArchive(String)
    case pathEscape(String)
    case targetExists(String)
    case notAnArchive(String)
    case needsExternalTool(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .badPassword: return "密码错误或压缩包已加密"
        case .corruptArchive(let m): return "压缩包可能已损坏：\(m)"
        case .pathEscape(let p): return "压缩包内含非法路径（疑似路径穿越攻击），已阻止：\(p)"
        case .targetExists(let p): return "目标已存在：\(p)"
        case .notAnArchive(let p): return "不支持的文件格式：\(p)"
        case .needsExternalTool(let t): return "需要外部工具：\(t)"
        case .unsupported(let m): return "不支持的操作：\(m)"
        }
    }
}

/// 压缩 / 解压核心引擎。
///
/// 全部使用 macOS 自带工具实现，不引入任何第三方依赖：
/// - ZIP     → /usr/bin/zip, /usr/bin/unzip
/// - TAR 系  → /usr/bin/tar (bsdtar)，自动支持 gz/bz2/xz/zstd
/// - 单文件流 → gzip / bzip2 / xz / zstd
/// - 7Z/RAR  → 若用户安装了 7-Zip 则自动启用
final class ArchiveEngine {

    // MARK: - 工具可用性

    struct Capabilities {
        var native: Bool
        var sevenZip: Bool
        var sevenZipBundled: Bool
        var note: String
        var detail: String
    }

    static var capabilities: Capabilities {
        let native = ToolLocator.hasNativeTools
        let seven = ToolLocator.sevenZip != nil
        let bundled = ToolLocator.isSevenZipBundled
        return Capabilities(
            native: native,
            sevenZip: seven,
            sevenZipBundled: bundled,
            note: native ? "系统工具（zip / bsdtar）" : "系统压缩工具缺失，功能将受限",
            detail: seven
                ? (bundled ? "已内置 · 支持 RAR / ISO / CAB" : "系统安装 · 支持 RAR / ISO / CAB")
                : "未安装 · RAR/7z 不可用"
        )
    }

    // MARK: - 目录统计

    /// 统计目录树的条目数与总字节（用于进度）
    static func measure(_ urls: [URL]) -> (entries: Int, bytes: Int64) {
        var entries = 0
        var bytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let en = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                ) {
                    for case let child as URL in en {
                        entries += 1
                        if let v = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                           v.isRegularFile == true {
                            bytes += Int64(v.fileSize ?? 0)
                        }
                    }
                }
                entries += 1
            } else {
                entries += 1
                let v = try? url.resourceValues(forKeys: [.fileSizeKey])
                bytes += Int64(v?.fileSize ?? 0)
            }
        }
        return (entries, bytes)
    }

    // MARK: - 压缩

    struct CompressOptions {
        var format: FormatSpec
        var level: CompressionLevel = .normal
        var password: String?
        var splitSizeMB: Int?          // 仅 ZIP / 7z
        var excludeDSStore: Bool = true
        var preserveSymlinks: Bool = false
    }

    /// 将多个输入打包为单个归档文件。
    ///
    /// - Parameter inputs: 要打包的文件 / 目录
    /// - Parameter outputURL: 输出归档路径（扩展名会自动修正）
    func compress(
        inputs: [URL],
        to outputURL: URL,
        options: CompressOptions,
        runner: ProcessRunner,
        progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {

        guard !inputs.isEmpty else { throw EngineError.unsupported("没有选择要压缩的文件") }

        // 确保输出目录存在
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 单文件流格式：只允许一个输入，且必须是文件
        if options.format.kind == .stream {
            guard inputs.count == 1 else {
                throw EngineError.unsupported("\(options.format.displayName) 只能压缩单个文件")
            }
            let src = inputs[0]
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else {
                throw EngineError.unsupported("\(options.format.displayName) 只能压缩单个文件")
            }
            return try compressStream(file: src, to: outputURL, format: options.format,
                                     level: options.level, runner: runner, progress: progress)
        }

        // 分卷
        if let splitMB = options.splitSizeMB, splitMB > 0, options.format.supportsSplit {
            return try compressSplit(inputs: inputs, to: outputURL, options: options,
                                    splitMB: splitMB, runner: runner, progress: progress)
        }

        switch options.format.id {
        case "zip":     return try compressZIP(inputs: inputs, to: outputURL, options: options, runner: runner, progress: progress)
        case "7z":      return try compress7z(inputs: inputs, to: outputURL, options: options, runner: runner, progress: progress)
        case "tar", "targz", "tarbz2", "tarxz", "tarzst":
            return try compressTar(inputs: inputs, to: outputURL, options: options, runner: runner, progress: progress)
        default:
            throw EngineError.unsupported("未知格式 \(options.format.id)")
        }
    }

    // MARK: ZIP 压缩

    private func compressZIP(
        inputs: [URL], to outputURL: URL, options: CompressOptions,
        runner: ProcessRunner, progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {

        let target = ensuringExtension(outputURL, ext: ".zip")
        try? FileManager.default.removeItem(at: target)

        let (entries, bytes) = Self.measure(inputs)
        progress(ProgressUpdate(fraction: 0, currentItem: "准备中…", bytesDone: 0, bytesTotal: bytes))

        // 在共同父目录下工作，保证归档内是相对路径（避免出现 /Users/... 绝对路径）
        let base = commonParent(inputs)
        var args: [String] = ["-r", options.level.zipFlag, "-X"]   // -X 丢弃扩展属性，跨平台更干净
        if options.preserveSymlinks { args.append("-y") }
        if options.password != nil { args += ["-P", ProcessRunner.secretToken] }
        args.append(target.path)                                   // 绝对路径，不依赖 cwd
        args.append(contentsOf: inputs.map { relativePath(of: $0, from: base) })

        if options.excludeDSStore {
            args += ["-x", "*.DS_Store", "-x", "__MACOSX/*", "-x", "*/.DS_Store"]
        }

        // 有密码时用 shell 包一层：argv 中只有占位符，真实密码走环境变量
        let cmd: ProcessRunner.Command
        if let pw = options.password {
            cmd = ProcessRunner.secretSafeCommand(executable: ToolLocator.zip, arguments: args, secret: pw)
        } else {
            cmd = ProcessRunner.plainCommand(executable: ToolLocator.zip, arguments: args)
        }

        var handled = 0
        let res = try runner.run(
            executable: cmd.executable,
            arguments: cmd.arguments,
            currentDirectory: base,
            secret: cmd.secret,
            onLine: { line in
                handled += 1
                let f = entries > 0 ? min(1.0, Double(handled) / Double(entries)) : nil
                progress(ProgressUpdate(fraction: f, currentItem: line, bytesDone: 0, bytesTotal: bytes))
            }
        )
        if runner.isCancelled { throw ProcessError.cancelled }
        guard res.succeeded, FileManager.default.fileExists(atPath: target.path) else {
            throw EngineError.corruptArchive(res.trimmedError.isEmpty
                ? "zip 返回 \(res.exitCode)" : res.trimmedError)
        }
        progress(ProgressUpdate(fraction: 1, currentItem: "完成", bytesDone: bytes, bytesTotal: bytes))
        return target
    }

    // MARK: 7z 压缩

    private func compress7z(
        inputs: [URL], to outputURL: URL, options: CompressOptions,
        runner: ProcessRunner, progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {
        guard let sevenZip = ToolLocator.sevenZip else {
            throw EngineError.needsExternalTool("7-Zip 未能加载（内置文件缺失，请重新构建）")
        }
        let target = ensuringExtension(outputURL, ext: ".7z")
        try? FileManager.default.removeItem(at: target)

        let (_, bytes) = Self.measure(inputs)
        progress(ProgressUpdate(fraction: 0, currentItem: "准备中…", bytesDone: 0, bytesTotal: bytes))

        let base = commonParent(inputs)
        var args = ["a", "-bsp1", "-bd", "-y", "-mx=\(options.level.rawValue)", target.path]
        if options.password != nil { args.append("-p\(ProcessRunner.secretToken)") }
        if let splitMB = options.splitSizeMB, splitMB > 0 { args.append("-v\(splitMB)m") }
        args.append(contentsOf: inputs.map { $0.path })

        let cmd: ProcessRunner.Command
        if let pw = options.password {
            cmd = ProcessRunner.secretSafeCommand(executable: sevenZip, arguments: args, secret: pw)
        } else {
            cmd = ProcessRunner.plainCommand(executable: sevenZip, arguments: args)
        }

        let res = try runner.run(
            executable: cmd.executable, arguments: cmd.arguments,
            currentDirectory: base, secret: cmd.secret,
            onLine: { line in
                // 7z 输出形如 " 45% 12 - filename"
                if let pct = Self.parsePercent(line) {
                    progress(ProgressUpdate(fraction: pct, currentItem: line, bytesDone: 0, bytesTotal: bytes))
                }
            }
        )
        if runner.isCancelled { throw ProcessError.cancelled }
        guard res.succeeded, FileManager.default.fileExists(atPath: target.path) else {
            throw EngineError.corruptArchive(res.trimmedError)
        }
        progress(ProgressUpdate(fraction: 1, currentItem: "完成", bytesDone: bytes, bytesTotal: bytes))
        return target
    }

    // MARK: TAR 系压缩

    private func compressTar(
        inputs: [URL], to outputURL: URL, options: CompressOptions,
        runner: ProcessRunner, progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {

        let target = ensuringExtension(outputURL, ext: options.format.ext)
        try? FileManager.default.removeItem(at: target)

        let (entries, bytes) = Self.measure(inputs)
        progress(ProgressUpdate(fraction: 0, currentItem: "准备中…", bytesDone: 0, bytesTotal: bytes))

        let base = commonParent(inputs)
        var args: [String] = ["-c", "-v"]
        switch options.format.id {
        case "targz":
            args.append("-z")
            if options.level != .normal { args += ["--options", "gzip:compression-level=\(options.level.rawValue)"] }
        case "tarbz2": args.append("-j")
        case "tarxz":  args.append("--xz")
        case "tarzst": args.append("--zstd")
        default: break
        }
        args += ["-f", target.path]
        args.append(contentsOf: inputs.map { relativePath(of: $0, from: base) })

        var handled = 0
        let res = try runner.run(
            executable: ToolLocator.tar, arguments: args, currentDirectory: base,
            onLine: { line in
                // bsdtar -v 每处理一个条目输出一行 "a path" / "x path"
                guard line.count >= 3 else { return }
                let first = line.first!
                guard "ax".contains(first) else { return }
                handled += 1
                let f = entries > 0 ? min(1.0, Double(handled) / Double(entries)) : nil
                progress(ProgressUpdate(fraction: f, currentItem: String(line.dropFirst(2)), bytesDone: 0, bytesTotal: bytes))
            }
        )
        if runner.isCancelled { throw ProcessError.cancelled }
        guard res.succeeded, FileManager.default.fileExists(atPath: target.path) else {
            throw EngineError.corruptArchive(res.trimmedError)
        }
        progress(ProgressUpdate(fraction: 1, currentItem: "完成", bytesDone: bytes, bytesTotal: bytes))
        return target
    }

    // MARK: 单文件流压缩

    private func compressStream(
        file: URL, to outputURL: URL, format: FormatSpec,
        level: CompressionLevel, runner: ProcessRunner,
        progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {

        let target = ensuringExtension(outputURL, ext: format.ext)
        try? FileManager.default.removeItem(at: target)

        let (_, bytes) = Self.measure([file])
        progress(ProgressUpdate(fraction: 0, currentItem: "压缩中…", bytesDone: 0, bytesTotal: bytes))

        let tool: String
        var args: [String]
        switch format.id {
        case "gz":
            tool = "/usr/bin/gzip"
            args = ["-c", "-f", "-S", ".gz", "-n", file.lastPathComponent]
            if level != .normal { args.insert("-\(min(9, max(1, level.rawValue)))", at: 0) }
        case "bz2":
            tool = "/usr/bin/bzip2"
            args = ["-c", "-f", file.lastPathComponent]
            if level != .normal { args.insert("-\(min(9, max(1, level.rawValue)))", at: 0) }
        case "xz":
            tool = ToolLocator.isExecutable("/usr/bin/xz") ? "/usr/bin/xz" : "/opt/homebrew/bin/xz"
            args = ["-c", "-f", "-T0", file.lastPathComponent]
            if level != .normal { args.insert("-\(min(9, max(0, level.rawValue)))", at: 0) }
        case "zst":
            tool = ToolLocator.isExecutable("/usr/bin/zstd") ? "/usr/bin/zstd" : "/opt/homebrew/bin/zstd"
            args = ["-c", "-f", file.lastPathComponent]
            if level != .normal { args.insert("-\(min(19, max(1, level.rawValue)))", at: 0) }
        default:
            throw EngineError.unsupported("未知流格式")
        }

        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw EngineError.needsExternalTool(tool)
        }

        // 通过 stdout 重定向写文件（避免 shell 注入）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        task.currentDirectoryURL = file.deletingLastPathComponent()
        let outPipe = Pipe()
        task.standardOutput = outPipe

        guard let fh = FileHandle(forWritingAtPath: target.path) ?? {
            FileManager.default.createFile(atPath: target.path, contents: nil)
            return FileHandle(forWritingAtPath: target.path)
        }() else {
            throw EngineError.corruptArchive("无法写入输出文件")
        }

        try task.run()
        var bytesWritten: Int64 = 0
        while true {
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            try? fh.write(contentsOf: chunk)
            bytesWritten += Int64(chunk.count)
            let f = bytes > 0 ? min(1.0, Double(bytesWritten) / Double(bytes)) : nil
            progress(ProgressUpdate(fraction: f, currentItem: file.lastPathComponent,
                                    bytesDone: bytesWritten, bytesTotal: bytes))
        }
        task.waitUntilExit()
        try? fh.close()

        guard task.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: target)
            throw EngineError.corruptArchive("\(format.displayName) 处理失败")
        }
        progress(ProgressUpdate(fraction: 1, currentItem: "完成", bytesDone: bytes, bytesTotal: bytes))
        return target
    }

    // MARK: - 分卷

    private func compressSplit(
        inputs: [URL], to outputURL: URL, options: CompressOptions,
        splitMB: Int, runner: ProcessRunner, progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {
        switch options.format.id {
        case "zip":
            let target = ensuringExtension(outputURL, ext: ".zip")
            let stem = target.deletingPathExtension().lastPathComponent
            try? FileManager.default.removeItem(at: target)
            let outDir = target.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            for suffix in ["z01", "z02", "z03", "z04", "z05", "z06", "z07", "z08"] {
                try? FileManager.default.removeItem(
                    at: outDir.appendingPathComponent("\(stem).\(suffix)"))
            }
            let (_, bytes) = Self.measure(inputs)
            let base = commonParent(inputs)
            // 分卷要求归档写在 cwd 下（zip 会生成 stem.z01 / stem.zip / stem.z0N）
            var args: [String] = ["-r", "-X", "-s", "\(splitMB)m", stem + ".zip"]
            if options.excludeDSStore { args += ["-x", "*.DS_Store", "-x", "__MACOSX/*"] }
            args.append(contentsOf: inputs.map { relativePath(of: $0, from: base) })

            let res = try runner.run(executable: ToolLocator.zip, arguments: args,
                                     currentDirectory: target.deletingLastPathComponent())
            if runner.isCancelled { throw ProcessError.cancelled }
            guard res.succeeded else { throw EngineError.corruptArchive(res.trimmedError) }
            progress(ProgressUpdate(fraction: 1, currentItem: "分卷完成", bytesDone: bytes, bytesTotal: bytes))
            return target
        default:
            return try compress7z(inputs: inputs, to: outputURL, options: options,
                                  runner: runner, progress: progress)
        }
    }

    // MARK: - 解压

    struct ExtractOptions {
        var password: String?
        var overwrite: OverwritePolicy = .ask
        /// 是否创建以压缩包命名的子目录
        var makeSubfolder: Bool = false
    }

    /// 解压归档文件，返回实际写入的目录
    @discardableResult
    func extract(
        archive archiveURL: URL,
        to directory: URL,
        options: ExtractOptions,
        runner: ProcessRunner,
        progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {

        let sig = ArchiveProbe.classify(archiveURL)
        let dest = options.makeSubfolder
            ? directory.appendingPathComponent(archiveURL.deletingPathExtension().lastPathComponent, isDirectory: true)
            : directory

        if FileManager.default.fileExists(atPath: dest.path) {
            switch options.overwrite {
            case .overwrite: break
            case .skip: return dest
            case .rename: return try extract(archive: archiveURL, to: uniqueDirectory(near: dest),
                                             options: ExtractOptions(password: options.password,
                                                                    overwrite: .overwrite,
                                                                    makeSubfolder: options.makeSubfolder),
                                             runner: runner, progress: progress)
            case .ask: break  // 由 UI 层先行处理
            }
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // ZIP 系：统一走内置 7-Zip，兼容传统 ZipCrypto 与 AES-256 加密
        if sig.formatID == "zip" {
            // 安全预检：拒绝绝对路径与 ../ 穿越
            if let names = try? listZipEntries(archiveURL, runner: runner) {
                for n in names {
                    if let evil = Self.maliciousEntry(n) {
                        throw EngineError.pathEscape(evil)
                    }
                }
            }
            return try extractWith7z(archiveURL, to: dest, options: options, sig: sig,
                                     runner: runner, progress: progress)
        }

        // 7Z / RAR → 需要外部工具
        if sig.formatID == "7z" || sig.formatID == "rar" {
            return try extractWith7z(archiveURL, to: dest, options: options, sig: sig,
                                     runner: runner, progress: progress)
        }

        // TAR / gzip / bzip2 / xz / zstd → bsdtar 通吃
        if ["tar", "targz", "tarbz2", "tarxz", "tarzst", "gzip", "bzip2", "xz", "zst"].contains(sig.formatID) {
            // 安全预检：tar 可能内含 ../ 路径
            try validateTarPaths(archiveURL, runner: runner)
            return try extractTar(archiveURL, to: dest, runner: runner, progress: progress)
        }

        throw EngineError.notAnArchive(archiveURL.lastPathComponent)
    }

    // MARK: ZIP 解压

    private func extractZIP(
        _ archive: URL, to dest: URL, options: ExtractOptions,
        runner: ProcessRunner, progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {

        // 先列出条目数，用于精确进度
        let totalEntries = countZipEntries(archive, runner: runner)
        progress(ProgressUpdate(fraction: 0, currentItem: "准备中…", bytesDone: 0,
                                bytesTotal: archiveSize(archive)))

        // 安全预检：拒绝绝对路径与 ../
        if let names = try? listZipEntries(archive, runner: runner) {
            for n in names {
                if let evil = Self.maliciousEntry(n) {
                    throw EngineError.pathEscape(evil)
                }
            }
        }

        var args: [String] = []
        switch options.overwrite {
        case .skip: args.append("-n")
        default: args.append("-o")
        }
        if options.password != nil { args += ["-P", ProcessRunner.secretToken] }
        args += [archive.path, "-d", dest.path]

        let cmd: ProcessRunner.Command
        if let pw = options.password {
            cmd = ProcessRunner.secretSafeCommand(executable: ToolLocator.unzip, arguments: args, secret: pw)
        } else {
            cmd = ProcessRunner.plainCommand(executable: ToolLocator.unzip, arguments: args)
        }

        var handled = 0
        let res = try runner.run(
            executable: cmd.executable, arguments: cmd.arguments, secret: cmd.secret,
            onLine: { line in
                guard line.contains("extracting:") || line.contains("inflating:")
                        || line.contains("creating:") else { return }
                handled += 1
                let f = totalEntries > 0 ? min(1.0, Double(handled) / Double(totalEntries)) : nil
                progress(ProgressUpdate(fraction: f, currentItem: line, bytesDone: 0, bytesTotal: 0))
            }
        )
        if runner.isCancelled { throw ProcessError.cancelled }

        guard res.succeeded else {
            let err = res.trimmedError.lowercased()
            if err.contains("password") || err.contains("encrypted") || err.contains("incorrect") {
                throw EngineError.badPassword
            }
            throw EngineError.corruptArchive(res.trimmedError)
        }
        progress(ProgressUpdate(fraction: 1, currentItem: "完成", bytesDone: 0, bytesTotal: 0))
        return dest
    }

    // MARK: TAR 解压

    private func extractTar(
        _ archive: URL, to dest: URL,
        runner: ProcessRunner, progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {

        progress(ProgressUpdate(fraction: nil, currentItem: "解压中…", bytesDone: 0, bytesTotal: 0))
        var handled = 0
        let res = try runner.run(
            executable: ToolLocator.tar,
            arguments: ["-x", "-v", "-f", archive.path, "-C", dest.path],
            onLine: { line in
                handled += 1
                progress(ProgressUpdate(fraction: nil, currentItem: line, bytesDone: 0, bytesTotal: 0))
            }
        )
        if runner.isCancelled { throw ProcessError.cancelled }
        guard res.succeeded else {
            throw EngineError.corruptArchive(res.trimmedError)
        }
        progress(ProgressUpdate(fraction: 1, currentItem: "完成", bytesDone: 0, bytesTotal: 0))
        return dest
    }

    // MARK: 7z / RAR 解压

    private func extractWith7z(
        _ archive: URL, to dest: URL, options: ExtractOptions, sig: ArchiveProbe.Signature,
        runner: ProcessRunner, progress: @escaping (ProgressUpdate) -> Void
    ) throws -> URL {
        guard let sevenZip = ToolLocator.sevenZip else {
            throw EngineError.needsExternalTool("解压 \(sig.displayName) 需要 7-Zip（内置文件缺失，请重新构建）")
        }
        var args = ["x", "-bsp1", "-bd", "-y", "-o\(dest.path)"]
        if options.password != nil { args.append("-p\(ProcessRunner.secretToken)") }
        args.append(archive.path)

        let cmd: ProcessRunner.Command
        if let pw = options.password {
            cmd = ProcessRunner.secretSafeCommand(executable: sevenZip, arguments: args, secret: pw)
        } else {
            cmd = ProcessRunner.plainCommand(executable: sevenZip, arguments: args)
        }

        let res = try runner.run(
            executable: cmd.executable, arguments: cmd.arguments, secret: cmd.secret,
            onLine: { line in
                if let pct = Self.parsePercent(line) {
                    progress(ProgressUpdate(fraction: pct, currentItem: line, bytesDone: 0, bytesTotal: 0))
                }
            }
        )
        if runner.isCancelled { throw ProcessError.cancelled }
        guard res.succeeded else {
            let err = res.trimmedError.lowercased()
            if err.contains("password") || err.contains("encrypted") { throw EngineError.badPassword }
            throw EngineError.corruptArchive(res.trimmedError)
        }
        progress(ProgressUpdate(fraction: 1, currentItem: "完成", bytesDone: 0, bytesTotal: 0))
        return dest
    }

    // MARK: - 安全校验

    /// 判断条目是否为恶意路径（绝对路径 / 路径穿越 / 软链接逃逸）
    static func maliciousEntry(_ name: String) -> String? {
        let n = name.replacingOccurrences(of: "\\", with: "/")
        if n.hasPrefix("/") { return name }
        if n.hasPrefix("~") { return name }
        let parts = n.split(separator: "/", omittingEmptySubsequences: true)
        var depth = 0
        for p in parts {
            if p == ".." {
                depth -= 1
                if depth < 0 { return name }
            } else if p != "." {
                depth += 1
            }
        }
        return nil
    }

    private func listZipEntries(_ archive: URL, runner: ProcessRunner) throws -> [String] {
        let res = try ProcessRunner.quick(ToolLocator.zipinfo, ["-1", archive.path])
        guard res.succeeded else { return [] }
        return res.stdout.split(separator: "\n").map(String.init)
    }

    private func countZipEntries(_ archive: URL, runner: ProcessRunner) -> Int {
        (try? listZipEntries(archive, runner: runner).count) ?? 0
    }

    private func validateTarPaths(_ archive: URL, runner: ProcessRunner) throws {
        guard let res = try? ProcessRunner.quick(ToolLocator.tar, ["-tf", archive.path]), res.succeeded else {
            return  // 列表失败不阻断，实际解压时仍由 tar 自身防护
        }
        for line in res.stdout.split(separator: "\n").map(String.init) {
            if let evil = Self.maliciousEntry(line) { throw EngineError.pathEscape(evil) }
        }
    }

    // MARK: - 辅助

    private func commonParent(_ urls: [URL]) -> URL {
        guard let first = urls.first else { return URL(fileURLWithPath: NSTemporaryDirectory()) }
        if urls.count == 1 {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            return isDir.boolValue ? first.deletingLastPathComponent() : first.deletingLastPathComponent()
        }
        var common: [String] = first.deletingLastPathComponent().pathComponents
        for u in urls.dropFirst() {
            let p = u.deletingLastPathComponent().pathComponents
            var i = 0
            while i < min(common.count, p.count), common[i] == p[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        let path = common.joined(separator: "/")
        return URL(fileURLWithPath: path.isEmpty ? "/" : path)
    }

    private func relativePath(of url: URL, from base: URL) -> String {
        let baseComps = base.standardizedFileURL.pathComponents
        let comps = url.standardizedFileURL.pathComponents
        var i = 0
        while i < min(baseComps.count, comps.count), baseComps[i] == comps[i] { i += 1 }
        return comps[i...].joined(separator: "/")
    }

    /// 确保输出路径带有目标扩展名。
    /// 复合扩展名（如 .tar.gz）会先剥掉原有的单段扩展再补全。
    private func ensuringExtension(_ url: URL, ext: String) -> URL {
        let name = url.lastPathComponent
        let lower = name.lowercased()

        // 已经以目标复合扩展结尾
        if lower.hasSuffix(ext) { return url }

        // 先剥离所有已知归档扩展，再拼接完整目标扩展
        var base = name
        let knownSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst",
                             ".tgz", ".tbz2", ".tbz", ".txz", ".tzst",
                             ".zip", ".tar", ".7z", ".rar", ".gz", ".bz2", ".xz", ".zst"]
        var changed = true
        while changed {
            changed = false
            let l = base.lowercased()
            for suf in knownSuffixes where l.hasSuffix(suf) && base.count > suf.count {
                base = String(base.dropLast(suf.count))
                changed = true
                break
            }
        }
        // 兼容 .tgz → .tar.gz 这类语义替换（简化为直接拼接）
        return url.deletingLastPathComponent().appendingPathComponent(base + ext)
    }

    private func uniqueDirectory(near url: URL) -> URL {
        var candidate = url
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) && n < 999 {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent) \(n)")
            n += 1
        }
        return candidate
    }

    private func archiveSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// 解析 " 45% 12 - name" 中的百分比
    private static func parsePercent(_ line: String) -> Double? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("%") else { return nil }
        let numPart = t.dropLast().trimmingCharacters(in: .whitespaces)
        // 形如 "45% 12"
        let head = numPart.split(separator: " ").first.map(String.init) ?? numPart
        guard let v = Double(head), v >= 0, v <= 100 else { return nil }
        return v / 100.0
    }
}
