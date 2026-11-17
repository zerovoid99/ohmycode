import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A viewer tab's content: the image, PDF or bytes, with a footer saying what the file is.
struct FileViewerView: View {
    let viewer: FileViewer
    let workspace: Workspace

    var body: some View {
        switch viewer.kind {
        case .image, .svg: ImageViewerView(viewer: viewer, workspace: workspace)
        case .pdf: PDFViewerView(viewer: viewer)
        case .hex: HexViewerView(viewer: viewer, workspace: workspace)
        }
    }
}

/// The strip under a viewer: facts on the left, buttons on the right.
private struct ViewerFooter<Trailing: View>: View {
    let facts: [String]
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(facts.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            trailing
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .themedBackground(.statusBar, fallback: .bar)
    }
}

private func percent(_ scale: CGFloat?) -> String {
    scale.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
}

/// Buttons for the zoom commands (also ⌘+, ⌘-, ⌘0 and pinching).
private struct ZoomButtons: View {
    let viewer: FileViewer

    var body: some View {
        HStack(spacing: 6) {
            Button { viewer.zoom(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom Out (⌘-)")
            Button { viewer.zoom(.fit) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Fit to Window (⌘0)")
            Button { viewer.zoom(.actualSize) } label: { Text("1:1").font(.callout.monospacedDigit()) }
                .help("Actual Size")
            Button { viewer.zoom(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom In (⌘+)")
        }
    }
}

// MARK: Images

/// What the footer says about an image.
struct ImageFileInfo: Equatable {
    var pixelSize: CGSize?
    var format: String
    var frameCount = 1

    /// Read from the file's header (ImageIO); SVG isn't a format ImageIO reads, so it's named by
    /// its extension.
    static func read(_ data: Data, url: URL) -> ImageFileInfo {
        let fallback = url.pathExtension.uppercased()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return ImageFileInfo(format: fallback)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let format = type?.preferredFilenameExtension?.uppercased() ?? fallback
        return ImageFileInfo(pixelSize: width.flatMap { w in height.map { CGSize(width: w, height: $0) } },
                             format: format == "JPEG" ? "JPEG" : format, frameCount: CGImageSourceGetCount(source))
    }

    var facts: [String] {
        var facts: [String] = []
        if let pixelSize { facts.append("\(Int(pixelSize.width)) × \(Int(pixelSize.height))") }
        facts.append(frameCount > 1 ? "\(format), \(frameCount) frames" : format)
        return facts
    }
}

private struct ImageViewerView: View {
    let viewer: FileViewer
    let workspace: Workspace
    @State private var image: NSImage?
    @State private var info: ImageFileInfo?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if failed {
                    ContentUnavailableView {
                        Label("This image can't be shown", systemImage: "photo.badge.exclamationmark")
                    } actions: {
                        Button("Open as Text Anyway") { workspace.openAsText(viewer) }
                    }
                } else {
                    ImageCanvas(viewer: viewer, image: image)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .editorBackground()
            Divider()
            ViewerFooter(facts: (info?.facts ?? []) + [FileViewer.formattedSize(viewer.fileSize), percent(viewer.displayedScale)]) {
                if viewer.kind == .svg {
                    Button("Open as Text") { workspace.openAsText(viewer) }
                        .help("Edit the SVG's source in the editor")
                }
                ZoomButtons(viewer: viewer)
            }
        }
        .task(id: viewer.version) { load() }
    }

    /// Read from the data, not the URL: NSImage could hand back what it read before a change.
    private func load() {
        guard let data = try? Data(contentsOf: viewer.url), let loaded = NSImage(data: data) else {
            image = nil
            failed = true
            return
        }
        let info = ImageFileInfo.read(data, url: viewer.url)
        // One image pixel to one point at 100% (an SVG has its own size).
        if viewer.kind == .image, let pixelSize = info.pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            loaded.size = pixelSize
        }
        self.info = info
        image = loaded
        failed = false
    }
}

private struct ImageCanvas: NSViewRepresentable {
    let viewer: FileViewer
    let image: NSImage?

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.onScaleChange = { [weak viewer] scale in
            if viewer?.displayedScale != scale { viewer?.displayedScale = scale }
        }
        viewer.zoomTarget = view
        return view
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        if view.image !== image { view.show(image) }
    }
}

/// The image at its size, magnified by the scroll view: fitted to the window until zoomed,
/// centered when smaller, over a checkerboard where it's transparent.
final class ImageScrollView: NSScrollView, ViewerZoomable {
    private let imageView = NSImageView()
    private let canvas = CheckerboardView()
    var onScaleChange: ((CGFloat) -> Void)?
    /// Fitted to the window (follows its size) until zoomed.
    private(set) var fitsWindow = true
    private(set) var image: NSImage?
    static let zoomStep: CGFloat = 1.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 32
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.animates = true
        canvas.addSubview(imageView)
        documentView = canvas
        NotificationCenter.default.addObserver(self, selector: #selector(didMagnify), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: NSImage?) {
        self.image = image
        imageView.image = image
        let size = image?.size ?? .zero
        canvas.frame = CGRect(origin: .zero, size: size)
        imageView.frame = canvas.bounds
        canvas.isHidden = image == nil
        if fitsWindow { fit() } else { reportScale() }
    }

    override func layout() {
        super.layout()
        if fitsWindow { fit() }
    }

    /// Small images stay at actual size; bigger ones shrink to fit.
    private func fit() {
        let size = canvas.frame.size
        let available = contentSize
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return }
        let scale = max(minMagnification, min(1, available.width / size.width, available.height / size.height))
        if abs(magnification - scale) > 0.0001 { magnification = scale }
        reportScale()
    }

    private func reportScale() {
        guard image != nil else { return }
        onScaleChange?(magnification)
    }

    @objc private func didMagnify() {
        fitsWindow = false
        reportScale()
    }

    private func zoom(to scale: CGFloat) {
        fitsWindow = false
        let visible = contentView.bounds
        setMagnification(min(maxMagnification, max(minMagnification, scale)), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        reportScale()
    }

    func zoomIn() { zoom(to: magnification * Self.zoomStep) }
    func zoomOut() { zoom(to: magnification / Self.zoomStep) }
    func zoomToActualSize() { zoom(to: 1) }

    func zoomToFit() {
        fitsWindow = true
        fit()
    }
}

/// Keeps a document smaller than the window in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let frame = documentView?.frame else { return rect }
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

/// Light and dark squares, showing through where the image is transparent.
private final class CheckerboardView: NSView {
    override var isFlipped: Bool { true }

    private static let pattern: NSColor = {
        let square: CGFloat = 8
        let image = NSImage(size: NSSize(width: square * 2, height: square * 2), flipped: false) { rect in
            NSColor(white: 0.93, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.78, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: square, height: square).fill()
            NSRect(x: square, y: square, width: square, height: square).fill()
            return true
        }
        return NSColor(patternImage: image)
    }()

    override func draw(_ dirtyRect: NSRect) {
        Self.pattern.setFill()
        dirtyRect.fill()
    }
}

// MARK: PDF

private struct PDFViewerView: View {
    let viewer: FileViewer
    @State private var pageCount = 0
    @State private var currentPage = 0
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if failed {
                    ContentUnavailableView("This PDF can't be shown", systemImage: "doc.questionmark")
                } else {
                    PDFCanvas(viewer: viewer, pageCount: $pageCount, currentPage: $currentPage, failed: $failed)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .editorBackground()
            Divider()
            ViewerFooter(facts: [
                pageCount == 0 ? "" : "Page \(currentPage) of \(pageCount)",
                FileViewer.formattedSize(viewer.fileSize),
                percent(viewer.displayedScale),
            ]) {
                ZoomButtons(viewer: viewer)
            }
        }
    }
}

private struct PDFCanvas: NSViewRepresentable {
    let viewer: FileViewer
    @Binding var pageCount: Int
    @Binding var currentPage: Int
    @Binding var failed: Bool

    final class Coordinator {
        var version = -1
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ZoomablePDFView {
        let view = ZoomablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        viewer.zoomTarget = view
        let center = NotificationCenter.default
        let pageChanged: @MainActor @Sendable () -> Void = { [weak view, weak viewer, $currentPage] in
            guard let view, let page = view.currentPage, let document = view.document else { return }
            $currentPage.wrappedValue = document.index(for: page) + 1
            if viewer?.displayedScale != view.scaleFactor { viewer?.displayedScale = view.scaleFactor }
        }
        context.coordinator.observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { _ in MainActor.assumeIsolated { pageChanged() } },
            center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { _ in MainActor.assumeIsolated { pageChanged() } },
        ]
        return view
    }

    func updateNSView(_ view: ZoomablePDFView, context: Context) {
        guard context.coordinator.version != viewer.version else { return }
        context.coordinator.version = viewer.version
        let document = PDFDocument(url: viewer.url)
        // Back to the page that was shown, after a change on disk.
        let page = view.currentPage.flatMap { view.document?.index(for: $0) }
        view.document = document
        if let page, let target = document?.page(at: min(page, max(0, (document?.pageCount ?? 1) - 1))) { view.go(to: target) }
        DispatchQueue.main.async {
            failed = document == nil
            pageCount = document?.pageCount ?? 0
            currentPage = view.currentPage.flatMap { document?.index(for: $0) }.map { $0 + 1 } ?? (pageCount > 0 ? 1 : 0)
            viewer.displayedScale = view.scaleFactor
        }
    }
}

final class ZoomablePDFView: PDFView, ViewerZoomable {
    func zoomIn() { zoomIn(nil) }
    func zoomOut() { zoomOut(nil) }
    func zoomToFit() { autoScales = true }

    func zoomToActualSize() {
        autoScales = false
        scaleFactor = 1
    }
}

// MARK: Hex

private struct HexViewerView: View {
    let viewer: FileViewer
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HexTable(viewer: viewer, font: AppSettings.shared.editorFont, theme: EditorTheme.observed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .editorBackground()
            Divider()
            ViewerFooter(facts: ["Binary", FileViewer.formattedSize(viewer.fileSize) + (viewer.fileSize >= 1024 ? " (\(viewer.fileSize.formatted()) bytes)" : ""), "Read-only"]) {
                Button("Open as Text Anyway") { workspace.openAsText(viewer) }
                    .help("Open the file in the text editor (saving it can damage a binary file)")
            }
        }
    }
}

/// The rows of a hex dump in a table, which only asks for the rows on screen: each reads its
/// 16 bytes through a `ChunkedFileReader`.
private struct HexTable: NSViewRepresentable {
    let viewer: FileViewer
    let font: NSFont
    let theme: EditorThemeDefinition

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var reader: ChunkedFileReader?
        var version = -1
        var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var foreground = NSColor.textColor
        var offsetColor = NSColor.secondaryLabelColor

        func numberOfRows(in tableView: NSTableView) -> Int {
            HexDump.rowCount(fileSize: reader?.fileSize ?? 0)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("hexRow")
            let field = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byClipping
                field.isSelectable = true
                return field
            }()
            let text = reader?.row(row) ?? ""
            let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: foreground])
            attributed.addAttribute(.foregroundColor, value: offsetColor, range: NSRange(location: 0, length: min(8, attributed.length)))
            field.attributedStringValue = attributed
            return field
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hex"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        var changed = false
        if coordinator.version != viewer.version {
            coordinator.version = viewer.version
            coordinator.reader = ChunkedFileReader(url: viewer.url)
            changed = true
        }
        if coordinator.font != font || coordinator.foreground != theme.foreground {
            coordinator.font = font
            coordinator.foreground = theme.foreground
            coordinator.offsetColor = theme.lineNumber
            table.rowHeight = ceil(font.ascender - font.descender + font.leading) + 2
            // Wide enough for the longest row, so it scrolls sideways rather than clipping.
            let sample = HexDump.row(offset: max(0, (coordinator.reader?.fileSize ?? 0) - 1), bytes: [UInt8](repeating: 0, count: HexDump.bytesPerRow))
            let width = ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 24
            table.tableColumns.first?.minWidth = width
            changed = true
        }
        if changed { table.reloadData() }
    }
}
