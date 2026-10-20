import SwiftUI

// MARK: - 设计令牌

/// 间距系统：8pt 栅格，统一命名避免魔法数字散落
enum Space {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 22
    static let xxl: CGFloat = 30
}

/// 圆角：遵循 macOS 连续曲率观感，整体收敛为系统控件尺度
enum Radius {
    static let chip: CGFloat = 5
    static let control: CGFloat = 7
    static let card: CGFloat = 10
    static let panel: CGFloat = 14
    static let hero: CGFloat = 18
}

// MARK: - 调色

/// 全局色板。中性色与强调色全部走系统语义，自动适配浅/深色，
/// 主强调色跟随用户在「系统设置 > 外观」中选择的强调色。
enum Ink {
    /// 全站统一沉稳蓝（唯一强调色），不随模式变化
    static let compress = Color(red: 0.16, green: 0.40, blue: 0.90)
    static let compressDeep = Color(red: 0.12, green: 0.32, blue: 0.78)
    /// 成功 / 就绪（仅状态色）
    static let extract = Color(nsColor: .systemGreen)
    static let extractDeep = Color(nsColor: .systemGreen)
    /// 警告 / 失败（沿用旧命名，便于调用处平滑迁移）
    static let warn = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    /// 主文字 / 次文字 / 三级文字
    static let primary = Color.primary
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    /// 卡片与分层
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let subtleFill = Color(nsColor: .underPageBackgroundColor)
}

/// 语义化的强调色。压缩 / 解压统一使用系统强调色，
/// 成功、警告、失败交由系统语义色表达，避免大面积高饱和铺色。
struct Accent {
    let main: Color
    let deep: Color
    let soft: Color

    static let pack = Accent(main: Ink.compress, deep: Ink.compressDeep,
                             soft: Ink.compress.opacity(0.10))
    static let unpack = Accent(main: Ink.compress, deep: Ink.compressDeep,
                               soft: Ink.compress.opacity(0.10))
}

// MARK: - 背景

/// 全局背景：交由窗口自身的 windowBackground，仅叠加极轻的材质，
/// 去掉此前的彩色径向渐变，保持原生桌面工具的干净底色。
struct AuroraBackground: View {
    var accent: Color

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                accent.opacity(0.03)
            }
            .ignoresSafeArea()
    }
}

// MARK: - 虚线边框

struct DashedRoundedRect: Shape {
    var radius: CGFloat = Radius.card
    var dash: [CGFloat] = [7, 5]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius),
                         style: .continuous)
        return p
    }
}

// MARK: - 卡片容器

/// 统一的分组卡外观：原生 controlBackground 填充 + 连续圆角，
/// 去掉白/黑双描边与彩色投影，贴近系统设置的分组列表观感。
struct CardSurface: ViewModifier {
    var padding: CGFloat = Space.lg
    var radius: CGFloat = Radius.card
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
            }
    }
}

extension View {
    func cardSurface(padding: CGFloat = Space.lg,
                     radius: CGFloat = Radius.card,
                     elevated: Bool = false) -> some View {
        modifier(CardSurface(padding: padding, radius: radius, elevated: elevated))
    }
}

// MARK: - 分组标题

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(Ink.tertiary)
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 胶囊标签

/// 中性小标签：浅灰底、次级文字，不再使用高饱和填充。
struct Pill: View {
    let text: String
    var color: Color = Ink.compress
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(color.opacity(filled ? 1 : 0.12))
            }
            .foregroundStyle(filled ? .white : color)
    }
}

// MARK: - 进度条

/// 原生线性进度条：复用系统 ProgressView 的轨道与动画，
/// indeterminate 走系统不定态循环，去掉自绘高光渐变。
struct SlimProgress: View {
    var value: Double          // 0...1
    var tint: Color
    var indeterminate: Bool = false

    var body: some View {
        if indeterminate {
            ProgressView()
                .controlSize(.small)
                .tint(tint)
        } else {
            ProgressView(value: clamped, total: 1)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(tint)
        }
    }

    private var clamped: Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

// MARK: - 工具

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        // ByteCountFormatter 对 0 会输出 "Zero KB"，这里统一显示为 "—"
        if b <= 0 { return "—" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    /// 路径压缩显示：太深时折叠中间层级，保留首尾可读
    static func path(_ p: String, maxComponents: Int = 4) -> String {
        let home = NSHomeDirectory()
        var text = p
        if text.hasPrefix(home) {
            text = "~" + text.dropFirst(home.count)
        }
        let comps = text.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count > maxComponents else { return text }
        let head = comps.prefix(1).joined(separator: "/")
        let tail = comps.suffix(maxComponents - 1).joined(separator: "/")
        return "\(head)/…/\(tail)"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 时 \((s % 3600) / 60) 分"
    }
}
