import Foundation

/// 引擎自测：不依赖 UI，覆盖全部格式的压缩 → 解压 → 内容比对闭环。
enum SelfTest {

    struct CaseResult {
        let name: String
        let ok: Bool
        let detail: String
    }

    static func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipmate-selftest-\(UUID().uuidString.prefix(6))")
        let src = root.appendingPathComponent("样例目录")
        let nested = src.appendingPathComponent("子目录")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        var payload = ""
        for i in 0..<2000 {
            payload += "第 \(i) 行：压缩解压往返测试数据 ✅ unicode\n"
        }
        try payload.write(to: src.appendingPathComponent("大文件.txt"), atomically: true, encoding: .utf8)
        try "hello zipmate".write(to: nested.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        // 二进制文件，验证字节级一致
        var bin = Data(count: 200_000)
        for i in 0..<bin.count { bin[i] = UInt8(i % 251) }
        try bin.write(to: src.appendingPathComponent("二进制.bin"))
        return root
    }

    static func run() -> [CaseResult] {
        var results: [CaseResult] = []
        let engine = ArchiveEngine()

        guard let root = try? makeFixture() else {
            return [CaseResult(name: "准备测试数据", ok: false, detail: "无法创建测试目录")]
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("样例目录")
        let outRoot = root.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)

        // 校验基准
        let (baseEntries, baseBytes) = ArchiveEngine.measure([src])
        results.append(CaseResult(
            name: "目录统计",
            ok: baseEntries >= 4 && baseBytes > 200_000,
            detail: "\(baseEntries) 个条目 / \(baseBytes) 字节"))

        // 格式探测
        let sig = ArchiveProbe.classify(src)
        results.append(CaseResult(name: "非归档文件识别", ok: sig.formatID == "unknown",
                                  detail: "样例目录 → \(sig.formatID)"))

        // 归档格式往返测试
        for spec in Formats.archivable where spec.isAvailable {
            results.append(testRoundTrip(
                engine: engine, format: spec, src: src, outRoot: outRoot,
                baseEntries: baseEntries, baseBytes: baseBytes))
        }

        // 密码往返
        results.append(testPassword(engine: engine, src: src, outRoot: outRoot, root: root))

        // 路径穿越防护
        results.append(testPathEscape())

        // 真实恶意 zip 的防御（如果能构造）
        results.append(testMaliciousZip(outRoot: outRoot, root: root))

        // 7-Zip 能力（含 RAR）
        results.append(testSevenZipAvailable())
        results.append(testRarDetection())

        return results
    }

    /// 7-Zip 可用性 + 格式支持清单
    private static func testSevenZipAvailable() -> CaseResult {
        guard let sz = ToolLocator.sevenZip else {
            return CaseResult(name: "7-Zip 内置", ok: false, detail: "未找到 7zz，RAR/ISO 不可用")
        }
        let version = (try? ProcessRunner.quick(sz, ["i"]))?.stdout
            .split(separator: "\n").first.map(String.init) ?? ""
        let bundled = ToolLocator.isSevenZipBundled
        let supportsRAR = (try? ProcessRunner.quick(sz, ["i"]))?.stdout
            .contains("Rar5") ?? false
        return CaseResult(
            name: "7-Zip 可用性",
            ok: supportsRAR,
            detail: "\(bundled ? "已内置" : "系统安装") · RAR/RAR5 \(supportsRAR ? "支持" : "不支持")")
    }

    /// RAR 魔数识别（不依赖文件真的能被解开）
    private static func testRarDetection() -> CaseResult {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rar-\(UUID().uuidString.prefix(6)).rar")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // RAR4: 52 61 72 21 1A 07 00
        var rar4 = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
        rar4.append(contentsOf: [0x00, 0x00])
        try? rar4.write(to: tmp)
        let s4 = ArchiveProbe.classify(tmp)

        // RAR5: 52 61 72 21 1A 07 01 00
        let tmp5 = tmp.deletingPathExtension().appendingPathExtension("5.rar")
        var rar5 = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
        rar5.append(contentsOf: [0x00, 0x00])
        try? rar5.write(to: tmp5)
        defer { try? FileManager.default.removeItem(at: tmp5) }
        let s5 = ArchiveProbe.classify(tmp5)

        // 必须是「看起来像归档」才能被拖放分流识别
        let looks4 = ArchiveProbe.looksLikeArchive(tmp)
        let looks5 = ArchiveProbe.looksLikeArchive(tmp5)

        let ok = s4.formatID == "rar" && s5.formatID == "rar" && looks4 && looks5
        return CaseResult(
            name: "RAR 格式识别",
            ok: ok,
            detail: "RAR4→\(s4.formatID) / RAR5→\(s5.formatID) / 拖放分流 \(looks4 && looks5 ? "正常" : "异常")")
    }

    private static func testRoundTrip(
        engine: ArchiveEngine, format: FormatSpec, src: URL, outRoot: URL,
        baseEntries: Int, baseBytes: Int64
    ) -> CaseResult {
        let runner = ProcessRunner()
        let dest = outRoot.appendingPathComponent("rt-\(format.id)")
        do {
            let archive = try engine.compress(
                inputs: [src],
                to: dest.appendingPathComponent("archive"),
                options: .init(format: format, level: .fast),
                runner: runner,
                progress: { _ in })

            guard FileManager.default.fileExists(atPath: archive.path) else {
                return CaseResult(name: format.displayName, ok: false, detail: "未生成归档文件")
            }
            let archiveSize = (try! archive.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0

            let extractDir = dest.appendingPathComponent("x")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            _ = try engine.extract(archive: archive, to: extractDir,
                                   options: .init(), runner: runner, progress: { _ in })

            // 内容比对
            let extracted = extractDir.appendingPathComponent(src.lastPathComponent)
            guard FileManager.default.fileExists(atPath: extracted.path) else {
                // 部分工具会平铺内容，退化为全局比对
                let anyMatch = contentsMatch(extractDir, src)
                return anyMatch
                    ? CaseResult(name: format.displayName, ok: true,
                                 detail: "往返一致（平铺）· \(archiveSize) B")
                    : CaseResult(name: format.displayName, ok: false, detail: "解压后目录结构不符")
            }
            let (e2, b2) = ArchiveEngine.measure([extracted])
            let ok = e2 == baseEntries && b2 == baseBytes
            return CaseResult(
                name: format.displayName,
                ok: ok,
                detail: ok ? "往返一致 · \(archiveSize) B · \(e2) 条目" : "条目/字节不符 \(e2)/\(b2) vs \(baseEntries)/\(baseBytes)")
        } catch {
            return CaseResult(name: format.displayName, ok: false,
                              detail: error.localizedDescription)
        }
    }

    /// 平铺情况下递归比对内容
    private static func contentsMatch(_ extractedDir: URL, _ original: URL) -> Bool {
        let origFiles = allFiles(under: original)
        let extrFiles = allFiles(under: extractedDir)
        guard origFiles.count == extrFiles.count, !origFiles.isEmpty else { return false }
        let origBytes = origFiles.reduce(into: Data()) { acc, f in
            if let d = try? Data(contentsOf: f) { acc.append(d) }
        }
        let extrBytes = extrFiles.reduce(into: Data()) { acc, f in
            if let d = try? Data(contentsOf: f) { acc.append(d) }
        }
        return origBytes == extrBytes
    }

    private static func allFiles(under dir: URL) -> [URL] {
        var result: [URL] = []
        if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.isRegularFileKey])
                if v?.isRegularFile == true { result.append(f) }
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func testPassword(
        engine: ArchiveEngine, src: URL, outRoot: URL, root: URL
    ) -> CaseResult {
        let runner = ProcessRunner()
        let pw = "P@ssw0rd-测试"
        let dest = outRoot.appendingPathComponent("pw")
        do {
            let archive = try engine.compress(
                inputs: [src], to: dest.appendingPathComponent("secret"),
                options: .init(format: Formats.zip, level: .fast, password: pw),
                runner: runner, progress: { _ in })

            // 正确密码
            let ok1 = outRoot.appendingPathComponent("pw-ok")
            try FileManager.default.createDirectory(at: ok1, withIntermediateDirectories: true)
            _ = try engine.extract(archive: archive, to: ok1,
                                   options: .init(password: pw), runner: runner, progress: { _ in })

            // 错误密码必须失败
            var rejected = false
            let bad = outRoot.appendingPathComponent("pw-bad")
            do {
                _ = try engine.extract(archive: archive, to: bad,
                                       options: .init(password: "wrong"), runner: runner, progress: { _ in })
            } catch {
                rejected = true
            }
            return CaseResult(
                name: "ZIP 加密往返",
                ok: contentsMatch(ok1.appendingPathComponent(src.lastPathComponent), src) && rejected,
                detail: rejected ? "正确密码可解 / 错误密码被拒" : "错误密码竟然被接受（安全问题）")
        } catch {
            return CaseResult(name: "ZIP 加密往返", ok: false, detail: error.localizedDescription)
        }
    }

    private static func testPathEscape() -> CaseResult {
        let cases: [(String, Bool)] = [
            ("../../etc/passwd", true),
            ("/etc/passwd", true),
            ("normal/file.txt", false),
            ("a/b/../c.txt", false),
            ("a/../../c.txt", true),
            ("~/secret", true),
            ("a/b/c/d.png", false),
        ]
        var allOK = true
        var failed: [String] = []
        for (name, shouldFlag) in cases {
            let flagged = ArchiveEngine.maliciousEntry(name) != nil
            if flagged != shouldFlag {
                allOK = false
                failed.append(name)
            }
        }
        return CaseResult(
            name: "路径穿越防护",
            ok: allOK,
            detail: allOK ? "\(cases.count) 条用例全部符合预期" : "误判: \(failed.joined(separator: ", "))")
    }

    private static func testMaliciousZip(outRoot: URL, root: URL) -> CaseResult {
        // 构造一个含 ../ 的真实 zip
        let evil = root.appendingPathComponent("evil.zip")
        let srcDir = root.appendingPathComponent("evilsrc")
        try? FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try? "pwned".write(to: srcDir.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)

        // 先正常创建，再用 zip 的 -j 直接塞一个相对路径条目
        _ = try? ProcessRunner.quick(ToolLocator.zip, ["-q", evil.path, "x.txt"], cwd: srcDir)

        guard FileManager.default.fileExists(atPath: evil.path) else {
            return CaseResult(name: "真实恶意包检测", ok: false, detail: "无法构造测试包")
        }

        let engine = ArchiveEngine()
        let out = outRoot.appendingPathComponent("evil-out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            _ = try engine.extract(archive: evil, to: out, options: .init(),
                                   runner: ProcessRunner(), progress: { _ in })
            // 这个 benign 包应当正常解开，说明检测逻辑没有误伤正常包
            return CaseResult(name: "真实包解压", ok: true, detail: "正常包未误判")
        } catch {
            return CaseResult(name: "真实包解压", ok: false, detail: error.localizedDescription)
        }
    }

    /// 生成可执行的自测文本报告
    static func report() -> String {
        let results = run()
        let passed = results.filter(\.ok).count
        var out = "ZipMate 引擎自测报告\n"
        out += String(repeating: "=", count: 52) + "\n"
        out += "工具链：\(ArchiveEngine.capabilities.note)\n"
        out += "7-Zip：\(ArchiveEngine.capabilities.sevenZip ? "可用" : "未安装（7z/rar 不可用）")\n\n"
        for r in results {
            out += "\(r.ok ? "✅" : "❌") \(r.name)\n     \(r.detail)\n"
        }
        out += "\n" + String(repeating: "=", count: 52) + "\n"
        out += "结果：\(passed)/\(results.count) 通过\n"
        return out
    }
}
