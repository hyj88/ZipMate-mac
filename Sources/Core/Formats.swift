import Foundation

/// 运行时工具探测。
///
/// 注意：macOS 上 PATH 中的 `zip` / `tar` 可能被第三方 shim 劫持，
/// 因此这里一律使用绝对路径，不做 PATH 查找。
enum ToolLocator {
    static let zip = "/usr/bin/zip"
    static let unzip = "/usr/bin/unzip"
    static let zipinfo = "/usr/bin/zipinfo"
    static let tar = "/usr/bin/tar"       // bsdtar
    static let ditto = "/usr/bin/ditto"
    static let sh = "/bin/sh"

    static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// 7-Zip 官方 macOS 版已内置到 app bundle；系统额外安装的也可用。
    /// 查找顺序：bundle 内 → 系统常见安装位置。
    static var sevenZip: String? {
        var candidates: [String] = []

        // 1. app bundle 内置（首选，随 app 分发）
        let bundleDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/7zz").path
        candidates.append(bundleDir)
        if Bundle.main.bundlePath.hasSuffix(".build") {
            // swiftc 直跑的调试场景
            let dev = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Core
                .deletingLastPathComponent()   // Sources
                .deletingLastPathComponent()   // ZipMate
                .appendingPathComponent("vendor/7zz").path
            candidates.append(dev)
        }

        // 2. 用户自行安装
        candidates += [
            "/opt/homebrew/bin/7z", "/opt/homebrew/bin/7zz",
            "/usr/local/bin/7z", "/usr/local/bin/7zz",
            "/Applications/Keka.app/Contents/MacOS/7za",
        ]
        return candidates.first(where: isExecutable)
    }

    /// 7-Zip 是否为随 app 内置（而非依赖系统安装）
    static var isSevenZipBundled: Bool {
        guard let p = sevenZip else { return false }
        return p.contains("Contents/Helpers") || p.contains("/vendor/")
    }

    static var hasNativeTools: Bool {
        isExecutable(zip) && isExecutable(unzip) && isExecutable(tar) && isExecutable(ditto)
    }
}

/// 归档格式描述。
enum FormatKind {
    /// 可容纳任意目录树 / 多文件的归档包
    case archive
    /// 只能作用于单个文件的压缩流
    case stream
}

struct FormatSpec: Identifiable, Hashable {
    let id: String
    let displayName: String
    /// 输出文件扩展名（含点）
    let ext: String
    let kind: FormatKind
    let supportsPassword: Bool
    let supportsSplit: Bool
    /// 跨平台友好（Windows / Linux 默认可解）
    let crossPlatform: Bool
    /// 运行时是否可用（例如依赖外部 7z）
    var isAvailable: Bool = true

    var fileExtension: String { ext }
}

enum Formats {

    static let zip = FormatSpec(
        id: "zip", displayName: "ZIP", ext: ".zip", kind: .archive,
        supportsPassword: true, supportsSplit: true, crossPlatform: true
    )

    static let tarGz = FormatSpec(
        id: "targz", displayName: "TAR + GZIP", ext: ".tar.gz", kind: .archive,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    static let tarBz2 = FormatSpec(
        id: "tarbz2", displayName: "TAR + BZIP2", ext: ".tar.bz2", kind: .archive,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    static let tarXz = FormatSpec(
        id: "tarxz", displayName: "TAR + XZ", ext: ".tar.xz", kind: .archive,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    static let tarZst = FormatSpec(
        id: "tarzst", displayName: "TAR + Zstandard", ext: ".tar.zst", kind: .archive,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    static let tar = FormatSpec(
        id: "tar", displayName: "TAR（不压缩）", ext: ".tar", kind: .archive,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    static let sevenZip = FormatSpec(
        id: "7z", displayName: "7Z（高压缩率）", ext: ".7z", kind: .archive,
        supportsPassword: true, supportsSplit: true, crossPlatform: false,
        isAvailable: ToolLocator.sevenZip != nil
    )

    /// RAR 解压：7-Zip 内置支持。
    /// 注意：RAR **压缩**受 unrar 许可限制，官方 7-Zip for macOS 不含编码器，
    /// 因此仅提供解压；需要产出 .rar 请用系统 tar/zip。
    static let rar = FormatSpec(
        id: "rar", displayName: "RAR（仅解压）", ext: ".rar", kind: .archive,
        supportsPassword: true, supportsSplit: false, crossPlatform: true,
        isAvailable: ToolLocator.sevenZip != nil
    )

    static let gzip = FormatSpec(
        id: "gz", displayName: "GZIP（单文件）", ext: ".gz", kind: .stream,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    static let xz = FormatSpec(
        id: "xz", displayName: "XZ（单文件）", ext: ".xz", kind: .stream,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    static let bzip2 = FormatSpec(
        id: "bz2", displayName: "BZIP2（单文件）", ext: ".bz2", kind: .stream,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    static let zstd = FormatSpec(
        id: "zst", displayName: "Zstandard（单文件）", ext: ".zst", kind: .stream,
        supportsPassword: false, supportsSplit: false, crossPlatform: true
    )

    /// 打包（多文件）可选格式
    static let archivable: [FormatSpec] = [zip, sevenZip, tarGz, tarXz, tarBz2, tarZst, tar]

    /// 仅支持解压的格式（受许可或工具能力限制）
    static let extractOnly: [FormatSpec] = [rar]

    /// 单文件压缩可选格式
    static let streamable: [FormatSpec] = [gzip, xz, bzip2, zstd]

    static func spec(id: String) -> FormatSpec? {
        (archivable + streamable + extractOnly).first { $0.id == id }
    }

    /// 根据文件名推断「最可能的归档格式」，用于自动选择输出格式
    static func inferFromFilename(_ name: String) -> FormatSpec? {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return tarGz }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".tbz") { return tarBz2 }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return tarXz }
        if lower.hasSuffix(".tar.zst") || lower.hasSuffix(".tzst") { return tarZst }
        if lower.hasSuffix(".tar") { return tar }
        if lower.hasSuffix(".zip") { return zip }
        if lower.hasSuffix(".7z") { return sevenZip }
        return nil
    }
}

/// 压缩级别
enum CompressionLevel: Int, CaseIterable, Identifiable {
    case store = 0
    case fastest = 1
    case fast = 3
    case normal = 6
    case high = 8
    case extreme = 9

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .store: return "仅存储"
        case .fastest: return "极速"
        case .fast: return "较快"
        case .normal: return "标准"
        case .high: return "较高"
        case .extreme: return "极限"
        }
    }

    var detail: String {
        switch self {
        case .store: return "不压缩，最快"
        case .fastest: return "体积略大，速度最快"
        case .fast: return "适合超大文件"
        case .normal: return "推荐，速度与体积均衡"
        case .high: return "更小，稍慢"
        case .extreme: return "最小体积，最慢"
        }
    }

    /// zip 的 -0..-9
    var zipFlag: String { "-\(rawValue)" }
}

/// 覆盖策略
enum OverwritePolicy: String, CaseIterable, Identifiable {
    case ask
    case overwrite
    case skip
    case rename

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "询问"
        case .overwrite: return "覆盖"
        case .skip: return "跳过"
        case .rename: return "自动重命名"
        }
    }
}
