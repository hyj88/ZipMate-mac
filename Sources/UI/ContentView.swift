import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 模式

enum WorkMode: String, CaseIterable, Identifiable {
    case compress
    case extract
    var id: String { rawValue }
    var title: String { self == .compress ? "压缩" : "解压" }
    var subtitle: String { self == .compress ? "打包文件与文件夹" : "提取压缩包内容" }
    var icon: String { self == .compress ? "archivebox.fill" : "tray.and.arrow.up.fill" }
    var accent: Accent { self == .compress ? .pack : .unpack }
}

// MARK: - 主视图

struct ContentView: View {
    @StateObject private var queue = JobQueue()
    @StateObject private var model = AppModel()
    @State private var purgeTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            HeroBar(model: model, queue: queue)

            ZStack {
                AuroraBackground(accent: model.mode.accent.main)
                workspace
            }
            .clipped()

            StatusStrip(queue: queue)
        }
        .frame(minWidth: 940, minHeight: 640)
        .tint(.accentColor)
        .dropRouter(model: model, queue: queue)
        .onAppear {
            model.wire(queue: queue)
            NotificationCenter.default.post(name: .zipmateViewReady, object: nil)
            queue.purgeExpired()
            purgeTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
                Task { @MainActor in queue.purgeExpired() }
            }
        }
        .onDisappear { purgeTimer?.invalidate() }
        .onChange(of: model.mode, initial: true) { _, _ in model.validate(queue: queue) }
    }

    @ViewBuilder
    private var workspace: some View {
        switch model.mode {
        case .compress: CompressWorkspace(model: model, queue: queue)
        case .extract:  ExtractWorkspace(model: model, queue: queue)
        }
    }
}

/// 供离屏快照使用的组合视图（与主界面共用组件，保证渲染结果一致）
struct PreviewShell: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: JobQueue

    var body: some View {
        VStack(spacing: 0) {
            HeroBar(model: model, queue: queue)

            ZStack {
                AuroraBackground(accent: model.mode.accent.main)
                Group {
                    switch model.mode {
                    case .compress: CompressWorkspace(model: model, queue: queue)
                    case .extract:  ExtractWorkspace(model: model, queue: queue)
                    }
                }
            }
            .clipped()

            StatusStrip(queue: queue)
        }
        .frame(minWidth: 940, minHeight: 640)
        .tint(.accentColor)
    }
}

// MARK: - 顶部操作条

struct HeroBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: JobQueue

    var body: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            HStack(spacing: 10) {
                ModeChoice(mode: .compress, isOn: model.mode == .compress) {
                    model.mode = .compress
                }
                ModeChoice(mode: .extract, isOn: model.mode == .extract) {
                    model.mode = .extract
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.mode == .compress ? "新建压缩任务" : "新建解压任务")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
            }

            Spacer(minLength: Space.md)

            if let reason = model.blockingReason, !model.canSubmit {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(reason).font(.caption)
                }
                .foregroundStyle(Ink.warn)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 4)
                .background(Capsule().fill(Ink.warn.opacity(0.12)))
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(.ultraThinMaterial)
    }

    private var subtitle: String {
        switch model.mode {
        case .compress:
            guard !model.items.isEmpty else { return "拖入文件或文件夹，也可点击添加" }
            return "\(model.items.count) 项 · \(Fmt.bytes(model.totalBytes)) · \(model.selectedFormat.displayName)"
        case .extract:
            guard !model.archives.isEmpty else { return "拖入压缩包，支持 RAR / ZIP / TAR 等" }
            let names = model.archives.prefix(2).map { $0.lastPathComponent }
            let extra = model.archives.count > 2 ? " 等 \(model.archives.count) 个" : ""
            return names.joined(separator: "、") + extra
        }
    }
}

/// 原生 prominent 主按钮：压缩蓝 / 解压绿，自带禁用与按压态。
struct PrimaryButton: View {
    let title: String
    let icon: String
    let enabled: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(tint)
        .disabled(!enabled)
    }
}

/// 顶部大卡片模式切换：图标 + 标题 + 副标题，选中为蓝浅底 + 蓝描边。
struct ModeChoice: View {
    let mode: WorkMode
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: mode.icon)
                    .font(.system(size: 19, weight: .medium))
                Text(mode.title)
                    .font(.body.weight(.semibold))
                Text(mode.subtitle)
                    .font(.caption2)
                    .foregroundStyle(Ink.tertiary)
            }
            .frame(width: 118, height: 60)
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isOn ? Ink.compress.opacity(0.10)
                               : (hovering ? Color.primary.opacity(0.05) : Color.clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(isOn ? Ink.compress.opacity(0.55) : Color.primary.opacity(0.08),
                                  lineWidth: isOn ? 1.5 : 0.75)
            }
            .foregroundStyle(isOn ? Ink.compress : .primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 压缩工作区

struct CompressWorkspace: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: JobQueue


    var body: some View {
        HSplitView {
            OptionsPanel(model: model, queue: queue)
                .frame(width: 300)

            GeometryReader { proxy in
            VStack(spacing: 0) {
                IntakeList(
                    icon: "plus.rectangle.on.folder",
                    headline: "拖入文件或文件夹",
                    hint: "支持多选 · 直接从 Finder 拖入",
                    urls: $model.items,
                    accent: .pack,
                    onAdd: pickFiles,
                    onDrop: { model.addItems($0, queue: queue) },
                    onRemoveAll: { model.items.removeAll() },
                    summary: model.items.isEmpty ? nil
                        : "\(model.items.count) 项 · \(Fmt.bytes(model.totalBytes))",
                    onSubmit: { model.submit(queue: queue) },
                    submitEnabled: model.canSubmit,
                    submitTitle: "开始压缩",
                    submitIcon: "archivebox.fill"
                )
                .frame(height: proxy.size.height * 0.75)

                JobBoard(queue: queue, accent: .pack)
                    .frame(height: proxy.size.height * 0.25)
            }
            }
            .frame(minWidth: 330)
        }
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = "选择要压缩的文件或文件夹"
        if p.runModal() == .OK { model.addItems(p.urls, queue: queue) }
    }
}

// MARK: - 解压工作区

struct ExtractWorkspace: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: JobQueue

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: Space.sm) {
                outputCard
                behaviorCard
                formatsCard
                Spacer(minLength: 0)
                hintCard
            }
            .padding(Space.md)
            .frame(width: 300)
            .background(.thinMaterial)

            GeometryReader { proxy in
            VStack(spacing: 0) {
                IntakeList(
                    icon: "tray.and.arrow.down",
                    headline: "拖入压缩包",
                    hint: "自动识别 ZIP / TAR / GZ / RAR / 7Z",
                    urls: $model.archives,
                    accent: .unpack,
                    onAdd: pickFiles,
                    onDrop: { model.addItems($0, queue: queue) },
                    onRemoveAll: { model.archives.removeAll() },
                    summary: model.archives.isEmpty ? nil : "\(model.archives.count) 个压缩包",
                    onSubmit: { model.submit(queue: queue) },
                    submitEnabled: model.canSubmit,
                    submitTitle: "开始解压",
                    submitIcon: "tray.and.arrow.down.fill"
                )
                .frame(height: proxy.size.height * 0.75)

                JobBoard(queue: queue, accent: .unpack)
                    .frame(height: proxy.size.height * 0.25)
            }
            }
            .frame(minWidth: 330)
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(text: "输出目录")
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.extractDir.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(Fmt.path(model.extractDir.path))
                        .font(.caption2)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                SecondaryButton(title: "更改", icon: "folder", action: pickDir)
            }
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
    }

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(text: "解压行为")
            ToggleRow(title: "创建同名子文件夹", isOn: $model.makeSubfolder)
            HStack {
                Text("同名冲突时").font(.callout)
                Spacer()
                Picker("", selection: $model.overwrite) {
                    ForEach(OverwritePolicy.allCases.filter { $0 != .ask }) { p in
                        Text(p.title).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 96)
            }
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
    }

    private var formatsCard: some View {
        let hasSevenZip = ArchiveEngine.capabilities.sevenZip
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(text: "支持格式",
                         trailing: hasSevenZip ? "含内置 7-Zip" : nil)
            FlowTags(
                items: hasSevenZip
                    ? ["ZIP", "TAR", "GZ", "BZ2", "XZ", "ZST", "RAR", "RAR5", "7Z", "ISO", "CAB", "DMG"]
                    : ["ZIP", "TAR", "GZ", "BZ2", "XZ", "ZST"],
                perRow: 3,
                highlighted: hasSevenZip ? ["RAR", "RAR5", "7Z", "ISO", "CAB", "DMG"] : [],
                highlightTint: Ink.compress
            )
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.message = "选择要解压的压缩包"
        p.allowedContentTypes = Self.archiveTypes
        if p.runModal() == .OK { model.addItems(p.urls, queue: queue) }
    }

    /// 底部提示：说明加密包如何处理
    private var hintCard: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "lock.circle")
                .font(.system(size: 12))
                .foregroundStyle(Ink.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("加密压缩包")
                    .font(.callout.weight(.medium))
                Text("遇到密码提示时解压会暂停，在任务卡片中重试并输入密码即可")
                    .font(.caption2)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func pickDir() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { model.extractDir = u }
    }

    static let archiveTypes: [UTType] = {
        var types: [UTType] = [.zip, .gzip]
        for id in ["org.gnu.gnu-zip-tar-archive", "public.tar-archive",
                   "com.pkware.zip-archive", "org.7-zip.7-zip-archive"] {
            if let t = UTType(id), !types.contains(t) { types.append(t) }
        }
        return types
    }()
}

// MARK: - 选项面板（压缩）

struct OptionsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: JobQueue
    @State private var pwVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                formatCard
                levelCard
                outputCard
                securityCard
                advancedCard
            }
            .padding(Space.md)
        }
        .background(.thinMaterial)
    }

    private var formatCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(text: "格式")
            Picker("", selection: $model.formatID) {
                ForEach(Formats.archivable) { f in
                    Text(f.displayName).tag(f.id).disabled(!f.isAvailable)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .onChange(of: model.formatID, initial: true) { _, _ in model.validate(queue: queue) }

            HStack(spacing: Space.xs) {
                Image(systemName: model.selectedFormat.crossPlatform
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text(model.selectedFormat.crossPlatform
                     ? "Windows / Linux 可直接打开" : "需对应解压工具")
                    .font(.caption2)
            }
            .foregroundStyle(model.selectedFormat.crossPlatform ? Ink.extract : Ink.warn)
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(text: "压缩级别")
            Picker("", selection: $model.level) {
                ForEach(CompressionLevel.allCases) { l in Text(l.title).tag(l) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            Text(model.level.detail)
                .font(.caption2)
                .foregroundStyle(Ink.tertiary)
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(text: "输出")
            TextField("文件名", text: $model.outputName)
                .textFieldStyle(.roundedBorder)
                .font(.callout)

            HStack(spacing: Space.sm) {
                Text(model.outputURL.lastPathComponent)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Ink.compress)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                SecondaryButton(title: "目录", icon: "folder", action: pickDir)
            }
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(text: "密码保护")
            ToggleRow(title: "启用密码", isOn: Binding(
                get: { model.usePassword && model.selectedFormat.supportsPassword },
                set: { model.usePassword = $0; if !$0 { model.password = "" } }
            ), enabled: model.selectedFormat.supportsPassword)

            if model.usePassword && model.selectedFormat.supportsPassword {
                HStack(spacing: Space.xs) {
                    Group {
                        if pwVisible {
                            TextField("输入密码", text: $model.password)
                        } else {
                            SecureField("输入密码", text: $model.password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)

                    Button { pwVisible.toggle() } label: {
                        Image(systemName: pwVisible ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.tertiary)
                            .frame(width: 20, height: 22)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 3) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 8))
                    Text("密码经环境变量传递，不出现在进程列表")
                        .font(.caption2)
                }
                .foregroundStyle(Ink.extract)
            } else if !model.selectedFormat.supportsPassword {
                Text("该格式不支持加密")
                    .font(.caption2)
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(text: "高级")
            ToggleRow(title: "分卷打包", isOn: $model.splitEnabled,
                      enabled: model.selectedFormat.supportsSplit)
            if model.splitEnabled {
                HStack(spacing: Space.xs) {
                    TextField("每卷", value: $model.splitMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("MB").font(.caption2).foregroundStyle(Ink.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
    }

    private func pickDir() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { model.outputDir = u }
    }
}

// MARK: - 通用控件

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var enabled: Bool = true

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
                .foregroundStyle(enabled ? .primary : Ink.tertiary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!enabled)
        }
    }
}

/// 原生 bordered 小按钮：图标 + 文字，跟随强调色。
struct SecondaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct FlowTags: View {
    let items: [String]
    /// 每行显示几个
    var perRow: Int = 3
    /// 高亮显示（通常是有额外工具支持的格式）
    var highlighted: Set<String> = []
    /// 高亮标签颜色（跟随当前模式：压缩蓝 / 解压绿）
    var highlightTint: Color = Ink.extract

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: perRow).map {
            Array(items[$0..<min($0 + perRow, items.count)])
        }
        VStack(spacing: Space.xs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Space.xs) {
                    ForEach(row, id: \.self) { t in
                        Text(t)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .fill(highlighted.contains(t)
                                          ? highlightTint.opacity(0.12)
                                          : Color.primary.opacity(0.05))
                            )
                            .foregroundStyle(highlighted.contains(t) ? highlightTint : Ink.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - 输入区（拖放 + 列表）

struct IntakeList: View {
    let icon: String
    let headline: String
    let hint: String
    @Binding var urls: [URL]
    let accent: Accent
    let onAdd: () -> Void
    let onDrop: ([URL]) -> Void
    let onRemoveAll: () -> Void
    let summary: String?
    /// 就近放在文件列表旁的主执行按钮（开始压缩/解压）；传 nil 则不显示
    var onSubmit: (() -> Void)? = nil
    var submitEnabled: Bool = true
    var submitTitle: String = "开始"
    var submitIcon: String = "arrow.down.circle.fill"

    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            if !urls.isEmpty {
            HStack(spacing: Space.sm) {
                Button(action: onAdd) {
                    Label("添加文件", systemImage: "plus")
                        .font(.callout.weight(.medium))
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(accent.main)

                if let onSubmit {
                    Button(action: onSubmit) {
                        Label(submitTitle, systemImage: submitIcon)
                            .font(.callout.weight(.medium))
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent.main)
                    .disabled(!submitEnabled)
                }

                Button(action: onRemoveAll) {
                    Label("清空", systemImage: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.tertiary)

                Spacer()

                if let summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(Ink.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
            .padding(.bottom, Space.sm)
            }

            if urls.isEmpty {
                dropPlaceholder
            } else {
                VStack(spacing: Space.xs) {
                    dropMoreStrip
                        .padding(.horizontal, Space.lg)
                    ScrollView {
                        LazyVStack(spacing: Space.xs) {
                            ForEach(urls, id: \.self) { u in
                                FileRow(url: u, accent: accent) { urls.removeAll { $0 == u } }
                            }
                        }
                        .padding(.horizontal, Space.lg)
                    }
                }
                .padding(.bottom, Space.md)
            }
        }
        .background(targeted ? accent.main.opacity(0.06) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            let g = DispatchGroup()
            let lock = NSLock()
            var found: [URL] = []

            func add(_ u: URL?) {
                guard let u else { return }
                lock.lock(); found.append(u); lock.unlock()
            }

            for p in providers {
                // 路径一：直接加载 URL 对象
                if p.canLoadObject(ofClass: URL.self) {
                    g.enter()
                    p.loadObject(ofClass: URL.self) { obj, _ in
                        add(obj as? URL)
                        g.leave()
                    }
                }
                // 路径二：public.file-url 的 Data 表示，独立兜底，不与路径一互斥
                if p.hasItemConformingToTypeIdentifier("public.file-url") {
                    g.enter()
                    p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                        if let d = data as? Data,
                           let u = URL(dataRepresentation: d, relativeTo: nil) {
                            add(u)
                        }
                        g.leave()
                    }
                }
            }
            g.notify(queue: .main) {
                let resolved = found
                    .map { $0.standardizedFileURL }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                var seen = Set<URL>()
                let unique = resolved
                    .filter { seen.insert($0).inserted }
                    .sorted { $0.path < $1.path }
                guard !unique.isEmpty else { return }
                onDrop(unique)
            }
            return true
        }
    }

    /// 有文件后常驻的虚线拖入区，提示可继续拖放
    private var dropMoreStrip: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 14, weight: .medium))
            Text("继续拖入文件到此处")
                .font(.caption)
        }
        .foregroundStyle(targeted ? accent.main : Ink.tertiary)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(targeted ? accent.main.opacity(0.7) : Color.primary.opacity(0.15),
                              style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                .background(targeted ? accent.main.opacity(0.06) : Color.clear)
        }
        .padding(.top, Space.xs)
    }

    private var dropPlaceholder: some View {
        VStack(spacing: Space.md) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(targeted ? 0.10 : 0.05))
                    .frame(width: 60, height: 60)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(targeted ? accent.main : Ink.secondary)
            }
            .scaleEffect(targeted ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)

            VStack(spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(targeted ? accent.main : .primary)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            Button(action: onAdd) {
                Label("浏览文件…", systemImage: "folder")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(accent.main)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.lg)
        .background {
            DashedRoundedRect(radius: Radius.card)
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [7, 5]))
                .foregroundStyle(targeted ? accent.main.opacity(0.7)
                                         : Color.primary.opacity(0.15))
                .padding(Space.md)
        }
        .contentShape(Rectangle())
    }
}

struct FileRow: View {
    let url: URL
    let accent: Accent
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Ink.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Fmt.path(url.deletingLastPathComponent().path))
                    .font(.caption2)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: Space.sm)

            if !isDir {
                Text(Fmt.bytes(size))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Ink.tertiary)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Ink.danger.opacity(0.8)
                                              : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { hovering = $0 }
    }

    private var size: Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private var isDir: Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private var icon: String {
        if isDir { return "folder.fill" }
        return ArchiveProbe.looksLikeArchive(url) ? "doc.zipper" : "doc"
    }
}

// MARK: - 任务看板

struct JobBoard: View {
    @ObservedObject var queue: JobQueue
    let accent: Accent

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                SectionLabel(text: "任务队列")
                if queue.activeCount > 0 {
                    Text("\(queue.activeCount) 进行中")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(accent.main)
                }
                Spacer()
                if doneCount > 0 {
                    Button { queue.removeFinished() } label: {
                        Label("清除已完成", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.secondary)
                }
                Text("\(doneCount)/\(queue.jobs.count) 完成")
                    .font(.caption2)
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)

            if queue.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Space.sm) {
                        ForEach(queue.jobs) { job in
                            JobCard(job: job, queue: queue, accent: accent)
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.md)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var doneCount: Int {
        queue.jobs.filter { if case .done = $0.state { return true }; return false }.count
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .ultraLight))
                .foregroundStyle(Ink.tertiary.opacity(0.6))
            Text("队列为空")
                .font(.callout.weight(.medium))
                .foregroundStyle(Ink.secondary)
            Text("添加文件后任务会显示在这里")
                .font(.caption2)
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobCard: View {
    let job: Job
    @ObservedObject var queue: JobQueue
    let accent: Accent
    @State private var hovering = false
    @State private var passwordInput = ""

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: statusIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.xs) {
                    Text(job.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Pill(text: job.kind == .compress ? job.format.displayName : "解压",
                         color: Ink.secondary)
                }

                if !job.state.isTerminal {
                    SlimProgress(value: job.fraction ?? 0,
                                  tint: accent.main,
                                  indeterminate: job.fraction == nil)
                }

                HStack(spacing: 5) {
                    Text(job.detail)
                        .font(.caption2)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let eta = job.eta {
                        Text("· \(Fmt.duration(eta))")
                            .font(.caption2)
                            .foregroundStyle(Ink.tertiary)
                    }
                }

                if job.needsPassword {
                    HStack(spacing: Space.xs) {
                        SecureField("输入密码", text: $passwordInput)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(maxWidth: 180)
                            .onSubmit { unlock() }
                        Button("解锁解压") { unlock() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: Space.xs)
            controls
        }
        .cardSurface(padding: Space.md, radius: Radius.control)
        .overlay {
            if isFailure {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Ink.danger.opacity(0.25), lineWidth: 0.75)
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var controls: some View {
        switch job.state {
        case .queued, .running:
            RoundIcon(icon: "stop.fill", tint: Ink.danger, help: "取消") { queue.cancel(job) }
        case .done(let url):
            HStack(spacing: Space.xs) {
                if job.kind == .extract {
                    RoundIcon(icon: "folder.fill", tint: Ink.extract, help: "打开解压目录") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    RoundIcon(icon: "magnifyingglass", tint: Ink.extract, help: "在 Finder 中显示压缩包") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                RoundIcon(icon: "xmark", tint: Ink.tertiary, help: "移除") {
                    queue.remove(job)
                }
            }
        case .failed:
            if job.needsPassword {
                RoundIcon(icon: "xmark", tint: Ink.tertiary, help: "移除") {
                    queue.remove(job)
                }
            } else {
                HStack(spacing: Space.xs) {
                    RoundIcon(icon: "arrow.clockwise", tint: Ink.warn, help: "重试") {
                        queue.retry(job)
                    }
                    RoundIcon(icon: "xmark", tint: Ink.tertiary, help: "移除") {
                        queue.remove(job)
                    }
                }
            }
        case .cancelled:
            RoundIcon(icon: "arrow.clockwise", tint: Ink.tertiary, help: "重试") {
                queue.retry(job)
            }
        }
    }

    private func unlock() {
        let pw = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty else { return }
        queue.retry(job, password: pw)
        passwordInput = ""
    }

    private var isFailure: Bool {
        if case .failed = job.state { return true }
        return false
    }

    private var statusIcon: String {
        switch job.state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .queued, .cancelled: return .secondary
        case .running: return accent.main
        case .done: return Ink.extract
        case .failed: return Ink.danger
        }
    }
}

/// 原生圆形小按钮：hover 浅灰底，色调仅用于图标。
struct RoundIcon: View {
    let icon: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - 状态条

struct StatusStrip: View {
    @ObservedObject var queue: JobQueue

    var body: some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)

            Text(text)
                .font(.caption)
                .foregroundStyle(Ink.secondary)

            Spacer()

            HStack(spacing: 3) {
                Image(systemName: ArchiveEngine.capabilities.sevenZip
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text(badge).font(.caption2)
            }
            .foregroundStyle(ArchiveEngine.capabilities.sevenZip ? Ink.extract : Ink.warn)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.sm)
        .background(.ultraThinMaterial)
    }

    private var text: String {
        if queue.activeCount > 0 { return "正在处理 \(queue.activeCount) 个任务" }
        let pending = queue.jobs.filter { $0.state == .queued }.count
        if pending > 0 { return "\(pending) 个任务排队中" }
        let done = queue.jobs.filter { if case .done = $0.state { return true }; return false }.count
        return done > 0 ? "已完成 \(done) 个任务" : "就绪"
    }

    private var badge: String {
        if ArchiveEngine.capabilities.sevenZipBundled { return "7-Zip 23.01 已内置" }
        if ArchiveEngine.capabilities.sevenZip { return "7-Zip（系统安装）" }
        return "7-Zip 未就绪"
    }

    private var indicatorColor: Color {
        queue.activeCount > 0 ? Color.accentColor : Color.secondary.opacity(0.5)
    }
}
