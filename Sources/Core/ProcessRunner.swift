import Foundation

/// 子进程执行结果
struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }

    var trimmedError: String {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

enum ProcessError: LocalizedError {
    case launchFailed(String)
    case toolMissing(String)
    case cancelled
    case failed(command: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "无法启动进程：\(msg)"
        case .toolMissing(let path): return "缺少系统工具：\(path)"
        case .cancelled: return "操作已取消"
        case .failed(let cmd, let code, let msg):
            return msg.isEmpty ? "命令失败（退出码 \(code)）：\(cmd)" : msg
        }
    }
}

/// 支持流式输出与取消的子进程执行器。
///
/// 设计要点：
/// 1. 同时读取 stdout / stderr，避免管道缓冲死锁；
/// 2. 密码等敏感信息只通过环境变量传递，绝不出现在 argv 中（`ps` 不可见）；
/// 3. 支持 SIGTERM → 宽限期 → SIGKILL 的分级取消。
final class ProcessRunner {

    /// 敏感信息统一走这个环境变量名
    static let secretEnvKey = "ZIPMATE_SECRET"

    private var process: Process?
    private var cancelled = false
    private let lock = NSLock()

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let proc = process
        lock.unlock()
        guard let proc, proc.isRunning else { return }
        proc.terminate()
        // 宽限期后仍未退出则强杀
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    /// 同步执行；`onLine` 在每行输出到达时回调（可用于实时进度）
    @discardableResult
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        secret: String? = nil,
        extraEnvironment: [String: String] = [:],
        stdinData: Data? = nil,
        onLine: ((String) -> Void)? = nil
    ) throws -> ProcessResult {

        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.toolMissing(executable)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let cwd = currentDirectory { task.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnvironment { env[k] = v }
        if let secret {
            env[Self.secretEnvKey] = secret
            // 关闭任何可能把环境变量打印出来的行为
            env["PS4"] = ""
        }
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        if let stdinData {
            let inPipe = Pipe()
            task.standardInput = inPipe
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(stdinData)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        var outData = Data()
        var errData = Data()
        let bufferLock = NSLock()

        let attach: (FileHandle) -> Void = { handle in
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else {
                    h.readabilityHandler = nil
                    return
                }
                bufferLock.lock()
                if handle === outPipe.fileHandleForReading { outData.append(chunk) }
                else { errData.append(chunk) }
                bufferLock.unlock()
                if let onLine {
                    let text = String(decoding: chunk, as: UTF8.self)
                    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        onLine(String(line))
                    }
                }
            }
        }
        attach(outPipe.fileHandleForReading)
        attach(errPipe.fileHandleForReading)

        lock.lock(); process = task; let alreadyCancelled = cancelled; lock.unlock()
        if alreadyCancelled { throw ProcessError.cancelled }

        do {
            try task.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        task.waitUntilExit()

        // 等待 readabilityHandler 排空剩余数据
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            bufferLock.lock()
            let drained = outData.isEmpty && errData.isEmpty
            bufferLock.unlock()
            if drained { break }
            usleep(20_000)
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw ProcessError.cancelled }

        let result = ProcessResult(
            exitCode: task.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
        return result
    }

    /// 便捷执行（忽略输出细节）
    @discardableResult
    static func quick(
        _ executable: String, _ arguments: [String],
        cwd: URL? = nil, secret: String? = nil
    ) throws -> ProcessResult {
        try ProcessRunner().run(executable: executable, arguments: arguments, currentDirectory: cwd, secret: secret)
    }
}
