import SwiftUI
import AppKit

/// 离屏渲染指定视图为 PNG，用于视觉验证（不依赖屏幕录制权限）
@MainActor
enum Snapshotter {

    @MainActor
    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)

        // 强制布局
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero,
                               size: CGSize(width: max(size.width, fitted.width),
                                            height: max(size.height, fitted.height)))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        if let cg = rep.cgImage {
            let w = Int(hosting.bounds.width * scale)
            let h = Int(hosting.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: hosting.bounds.width, height: hosting.bounds.height))
                if let out = ctx.makeImage() {
                    return NSBitmapImageRep(cgImage: out)
                }
            }
        }
        return rep
    }

    @MainActor
    static func save<V: View>(_ view: V, to path: String, size: CGSize, scale: CGFloat = 2) -> Bool {
        guard let rep = render(view, size: size, scale: scale),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}
