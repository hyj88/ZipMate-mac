import Foundation

/// 文件真实类型探测（magic number），不依赖扩展名。
enum ArchiveProbe {

    struct Signature {
        let formatID: String
        let displayName: String
        let kindHint: KindHint
        enum KindHint { case archive, stream }
    }

    private struct ByteReader {
        let data: Data
        init(_ url: URL, bytes: Int) throws {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = handle.readData(ofLength: bytes)
        }
        func u8(_ offset: Int) -> UInt8? {
            guard offset >= 0, offset < data.count else { return nil }
            return data[data.startIndex + offset]
        }
        func str(_ offset: Int, _ length: Int) -> String? {
            guard offset >= 0, offset + length <= data.count else { return nil }
            let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
            return String(data: slice, encoding: .isoLatin1)
        }
    }

    /// 读取文件头做类型判定
    static func detect(_ url: URL) -> Signature? {
        guard let br = try? ByteReader(url, bytes: 512) else { return nil }

        // ZIP: PK\x03\x04 / PK\x05\x06 (空包) / PK\x07\x08
        if br.u8(0) == 0x50, br.u8(1) == 0x4B {
            let third = br.u8(2)
            if third == 0x03 || third == 0x05 || third == 0x07 {
                return Signature(formatID: "zip", displayName: "ZIP 归档", kindHint: .archive)
            }
        }

        // 7Z: 37 7A BC AF 27 1C
        let sevenZip: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
        if matches(br, sevenZip, at: 0) {
            return Signature(formatID: "7z", displayName: "7Z 归档", kindHint: .archive)
        }

        // RAR: 52 61 72 21 1A 07
        let rar: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]
        if matches(br, rar, at: 0) {
            return Signature(formatID: "rar", displayName: "RAR 归档", kindHint: .archive)
        }

        // GZIP: 1F 8B
        if br.u8(0) == 0x1F, br.u8(1) == 0x8B {
            return Signature(formatID: "gzip", displayName: "GZIP 压缩流", kindHint: .stream)
        }

        // BZIP2: 42 5A 68 ('BZh')
        if br.u8(0) == 0x42, br.u8(1) == 0x5A, br.u8(2) == 0x68 {
            return Signature(formatID: "bzip2", displayName: "BZIP2 压缩流", kindHint: .stream)
        }

        // XZ: FD 37 7A 58 5A 00
        let xz: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
        if matches(br, xz, at: 0) {
            return Signature(formatID: "xz", displayName: "XZ 压缩流", kindHint: .stream)
        }

        // Zstandard: 28 B5 2F FD
        let zstd: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        if matches(br, zstd, at: 0) {
            return Signature(formatID: "zst", displayName: "Zstandard 压缩流", kindHint: .stream)
        }

        // TAR: 头部第 257 字节为 "ustar"
        if br.str(257, 5) == "ustar" {
            return Signature(formatID: "tar", displayName: "TAR 归档", kindHint: .archive)
        }

        // AppleDouble / DiskImage 等一律交给扩展名兜底
        return nil
    }

    private static func matches(_ br: ByteReader, _ bytes: [UInt8], at offset: Int) -> Bool {
        for (i, b) in bytes.enumerated() where br.u8(offset + i) != b { return false }
        return true
    }

    /// 综合判定：优先 magic number，其次扩展名
    static func classify(_ url: URL) -> Signature {
        if let sig = detect(url) { return sig }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "zip": return Signature(formatID: "zip", displayName: "ZIP 归档", kindHint: .archive)
        case "7z": return Signature(formatID: "7z", displayName: "7Z 归档", kindHint: .archive)
        case "rar": return Signature(formatID: "rar", displayName: "RAR 归档", kindHint: .archive)
        case "gz", "gzip": return Signature(formatID: "gzip", displayName: "GZIP 压缩流", kindHint: .stream)
        case "bz2": return Signature(formatID: "bzip2", displayName: "BZIP2 压缩流", kindHint: .stream)
        case "xz": return Signature(formatID: "xz", displayName: "XZ 压缩流", kindHint: .stream)
        case "zst", "zstd": return Signature(formatID: "zst", displayName: "Zstandard 压缩流", kindHint: .stream)
        case "tar": return Signature(formatID: "tar", displayName: "TAR 归档", kindHint: .archive)
        default: return Signature(formatID: "unknown", displayName: "未知格式", kindHint: .archive)
        }
    }

    /// 是否「看起来像」一个压缩包（用于拖放自动分流）
    static func looksLikeArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let knownSuffixes = [".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2",
                             ".tar.xz", ".txz", ".tar.zst", ".tzst", ".7z", ".rar", ".gz",
                             ".bz2", ".xz", ".zst"]
        if knownSuffixes.contains(where: { name.hasSuffix($0) }) { return true }
        return classify(url).formatID != "unknown"
    }
}
