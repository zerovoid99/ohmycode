import AppKit

/// A peek (Peek Definition, Peek References…): a panel inside an editor, below the cursor's
/// line, with a small editor of the place found and, when there are several, a list of them
/// by file. The small editor is an ordinary editor of the file's document (the open tab's,
/// when there is one): edits there are that document's, with its undo.
///
/// The room for the panel is made in the editor's own layout, like a VS Code view zone: its
/// layout manager lays the line out as a fragment as much taller as the panel (see
/// `PeekSpacer`), so the lines below move down rather than being covered, while the gutter's
/// numbers stay on their lines (they're drawn by the line fragments, at the top). The text
/// isn't touched, so other editors of the document (a split, the peek's own small editor on
/// the same file) don't get the room. The panel is a subview of the text view at the bottom
/// of the line: it scrolls with the text.
@MainActor
final class PeekController: NSObject {
    private(set) weak var host: EditorController?
    private weak var workspace: Workspace?
    private(set) var model: PeekModel
    /// The start of the line the peek hangs from (in the host's document), and its end.
    private(set) var anchor: Int
    private(set) var anchorLineEnd: Int
    let panel = PeekPanelView()
    /// The small editor (of the selected place's file).
    private(set) var editor: EditorController?
    /// Documents read for this peek alone (no tab had them).
    private(set) var ownedDocuments: [EditorDocument] = []
    private(set) var isClosed = false
    private var observers: [NSObjectProtocol] = []
    /// Lays the anchor's line out taller in the host's editor.
    private let spacer = PeekSpacer()

    /// Lines of the file shown in the small editor.
    static let visibleLines = 14

    init(host: EditorController, model: PeekModel, anchor location: Int, workspace: Workspace?) {
        self.host = host
        self.model = model
        self.workspace = workspace
        let index = host.document.lineIndex
        let line = index.line(containing: min(location, host.document.textStorage.length))
        anchor = index.lineStarts[line]
        anchorLineEnd = line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : host.document.textStorage.length
        super.init()
        panel.onClose = { [weak self] in self?.close() }
        panel.onOpen = { [weak self] in self?.openSelection() }
        panel.onSelect = { [weak self] index in self?.select(index, focusList: true) }
        panel.onMove = { [weak self] offset in self?.move(by: offset) }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The panel's height: the small editor's lines, its header and borders.
    var panelHeight: CGFloat {
        let lineHeight = host?.lineHeight ?? ceil(EditorTheme.font.ascender - EditorTheme.font.descender + EditorTheme.font.leading)
        return CGFloat(Self.visibleLines) * lineHeight + 12 + PeekPanelView.headerHeight + 2 * PeekPanelView.borderWidth
    }

    // MARK: Opening and closing

    func open() {
        guard let host, let textView = host.textView else { return }
        panel.frame.size.height = panelHeight
        textView.addSubview(panel, positioned: .above, relativeTo: nil)
        if let layoutManager = textView.textLayoutManager, layoutManager.delegate == nil || layoutManager.delegate is PeekSpacer {
            layoutManager.delegate = spacer
        }
        applySpacing()
        positionPanel()
        panel.reload(model)
        showSelected(focusList: model.showsList)
        let storage = host.document.textStorage
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageEdited() }
        })
        if let clip = textView.enclosingScrollView?.contentView {
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(center.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.positionPanel() }
                })
            }
        }
        observers.append(center.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                self.panel.needsDisplay = true
                self.panel.reload(self.model)
                self.applySpacing() // the font (line height) may have changed
            }
        })
        // The line and the panel in view.
        textView.scrollToVisible(panel.frame.insetBy(dx: 0, dy: -host.lineHeight))
    }

    /// Shows other places (peeking again from inside the peek).
    func show(_ model: PeekModel) {
        self.model = model
        panel.reload(model)
        showSelected(focusList: model.showsList)
    }

    /// Closes the panel and takes its room away. `refocus`: the editor it was in gets the focus.
    func close(refocus: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let hadFocus = panel.window.map { window in (window.firstResponder as? NSView)?.isDescendant(of: panel) == true } ?? false
        if hadFocus, let textView = host?.textView { panel.window?.makeFirstResponder(textView) }
        spacer.set(anchor: nil, height: 0)
        relayOutAnchorLine()
        if let layoutManager = host?.textView?.textLayoutManager, layoutManager.delegate === spacer { layoutManager.delegate = nil }
        tearDownEditor()
        panel.removeFromSuperview()
        for document in ownedDocuments { workspace?.releasePeekDocument(document, group: host?.group) }
        ownedDocuments = []
        if host?.peek === self { host?.peek = nil }
        if refocus || hadFocus { host?.focus() }
    }

    /// Opens the selected place in a tab, where the small editor's cursor is.
    func openSelection() {
        guard let workspace, let entry = model.selected else { return }
        let range = editor?.textView.selectedRange() ?? NSRange(location: 0, length: 0)
        close(refocus: false)
        workspace.openPeekLocation(entry.url, range: range)
    }

    // MARK: The selected place

    func select(_ index: Int, focusList: Bool) {
        guard index != model.selection || editor == nil else { return }
        model.select(index)
        showSelected(focusList: focusList)
    }

    func move(by offset: Int) {
        model.move(by: offset)
        showSelected(focusList: true)
    }

    /// Shows the selected place in the small editor (a new one for another file).
    private func showSelected(focusList: Bool) {
        guard let entry = model.selected else { return }
        panel.select(model.selection)
        panel.setHeader(entry: entry, model: model)
        if let editor, FileWatcher.canonicalPath(editor.document.url) == FileWatcher.canonicalPath(entry.url) {
            revealSelected(focusList: focusList)
            return
        }
        guard let workspace, let (document, owned) = workspace.peekDocument(for: entry.url) else { return }
        if owned, !ownedDocuments.contains(where: { $0 === document }) { ownedDocuments.append(document) }
        tearDownEditor()
        let controller = EditorController(document: document)
        controller.peekHost = self
        let view = controller.makeView()
        panel.setEditorView(view)
        editor = controller
        panel.layoutSubtreeIfNeeded()
        // After the editor's own setup (it takes the focus and restores a view state then).
        DispatchQueue.main.async { [weak self] in self?.revealSelected(focusList: focusList) }
    }

    private func revealSelected(focusList: Bool) {
        guard !isClosed, let editor, editor.textView != nil, let entry = model.selected else { return }
        let document = editor.document
        let range = document.range(for: entry.range)
        document.unfold(containing: range)
        editor.textView.setSelectedRange(range)
        editor.scrollLineToTop(max(0, entry.match.line - 3))
        let responder: NSView = focusList && model.showsList ? panel.tableView : editor.textView
        panel.window?.makeFirstResponder(responder)
    }

    private func tearDownEditor() {
        guard let editor else { return }
        self.editor = nil
        editor.dismissPopups()
        if let window = panel.window, let responder = window.firstResponder as? NSView,
           let view = editor.containerView, responder.isDescendant(of: view) {
            window.makeFirstResponder(panel.tableView)
        }
        editor.containerView?.removeFromSuperview()
        let document = editor.document
        document.highlighter?.removeClient(editor)
        // Actions at the cursor go to the tab's editor again.
        if document.editor === editor {
            let others = document.editors.filter { $0 !== editor && $0.peekHost == nil }
            document.editor = others.first { $0 === host } ?? others.first { !$0.isParked } ?? others.first
        }
    }

    // MARK: The room below the line

    /// The room below the anchor's line is the panel's height (again: the font may have changed).
    func applySpacing() {
        spacer.set(anchor: anchor, height: panelHeight)
        relayOutAnchorLine()
    }

    /// Has the anchor's line laid out again in every editor of the document, which makes the
    /// host's layout manager ask the spacer for its fragment afresh. Attribute-only: the
    /// document doesn't take it for an edit.
    private func relayOutAnchorLine() {
        guard let storage = host?.document.textStorage, storage.length > 0 else { return }
        let start = min(anchor, storage.length - 1)
        let end = min(max(anchorLineEnd + 1, start + 1), storage.length)
        storage.beginEditing()
        storage.edited(.editedAttributes, range: NSRange(location: start, length: end - start), changeInLength: 0)
        storage.endEditing()
    }

    /// Puts the panel at the bottom of the anchor's line, across the visible width.
    func positionPanel() {
        guard !isClosed, let host, let textView = host.textView else { return }
        let length = host.document.textStorage.length
        let index = host.document.lineIndex
        let line = index.line(containing: min(anchor, length))
        let start = index.lineStarts[line]
        let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : length
        if start != anchor || end != anchorLineEnd {
            anchor = start
            anchorLineEnd = end
            spacer.set(anchor: start, height: panelHeight)
        }
        guard let line = host.rect(for: NSRange(location: start, length: end - start)) else { return }
        let visible = textView.visibleRect
        let frame = NSRect(x: visible.minX, y: line.maxY, width: visible.width, height: panelHeight)
        if panel.frame != frame { panel.frame = frame }
    }

    /// The host's text changed: typing (or undo) in the host at or above the peek's line closes
    /// it; other edits move it with its line.
    private func storageEdited() {
        guard !isClosed, let host else { return }
        let storage = host.document.textStorage
        guard storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        let oldLength = edited.length - storage.changeInLength
        let fromHost = host.textView?.window?.firstResponder === host.textView
        if PeekModel.editCloses(editLocation: edited.location, anchorLineEnd: anchorLineEnd, fromHostEditor: fromHost) {
            // Not during the edit (that would change the text's attributes while it's processed).
            DispatchQueue.main.async { [weak self] in self?.close(refocus: false) }
            return
        }
        anchor = PeekModel.shifted(anchor, editLocation: edited.location, oldLength: oldLength, newLength: edited.length)
        anchorLineEnd = PeekModel.shifted(anchorLineEnd, editLocation: edited.location, oldLength: oldLength, newLength: edited.length)
        // The lines edited are laid out again, the spacer asked again for them: it needs to
        // know where the line is now. (A line not edited keeps the fragment it has.)
        spacer.set(anchor: anchor, height: panelHeight)
    }
}

/// Lays out the line a peek hangs from (the paragraph with `anchor`) as a taller fragment, in
/// the host editor's layout manager only. Not tied to the main actor: TextKit asks it from
/// inside layout (see `FoldingDelegate`); it reads its own lock-protected copy of the anchor.
final class PeekSpacer: NSObject, NSTextLayoutManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var anchor: Int?
    private var height: CGFloat = 0

    func set(anchor: Int?, height: CGFloat) {
        lock.withLock {
            self.anchor = anchor
            self.height = height
        }
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let (anchor, height) = lock.withLock { (self.anchor, self.height) }
        if let anchor, height > 0, let range = textElement.elementRange, let content = textLayoutManager.textContentManager {
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            if start <= anchor, anchor < max(end, start + 1) {
                let fragment = PeekSpacerFragment(textElement: textElement, range: range)
                fragment.extraHeight = height
                return fragment
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// A line's fragment with room below it (TextKit stacks the next one at its frame's bottom).
final class PeekSpacerFragment: NSTextLayoutFragment, @unchecked Sendable {
    nonisolated(unsafe) var extraHeight: CGFloat = 0

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height += extraHeight
        return frame
    }
}

// MARK: The editor's side

extension EditorController {
    /// A click in the editor (outside its peek, whose views take their own clicks) closes the
    /// peek, after the click has put the cursor where it was meant to (the text moves up then).
    func peekClicked() {
        guard let peek else { return }
        DispatchQueue.main.async { [weak peek] in peek?.close(refocus: false) }
    }

    /// Esc in an editor with a peek, or in a peek's editor, closes the peek.
    func closePeekOnEscape() -> Bool {
        if let peek {
            peek.close()
            return true
        }
        if let peekHost {
            peekHost.close()
            return true
        }
        return false
    }

    /// The Peek submenu of the context menu.
    func peekMenuItem(supports: (LanguageClient.Feature, ExtensionHost.ProviderKind) -> Bool) -> NSMenuItem {
        let menu = NSMenu(title: "Peek")
        let f12 = String(Character(UnicodeScalar(NSF12FunctionKey)!))
        let keys: [PeekKind: (String, NSEvent.ModifierFlags)] = [
            .definition: (f12, .option), .references: (f12, [.option, .shift]), .implementation: (f12, [.command, .shift]),
        ]
        for kind in PeekKind.allCases {
            let enabled = kind.feature.map { supports($0, kind.providerKind) } ?? true
            let item = NSMenuItem(title: kind.title, action: enabled ? #selector(contextPeek) : nil, keyEquivalent: keys[kind]?.0 ?? "")
            item.keyEquivalentModifierMask = keys[kind]?.1 ?? []
            item.representedObject = kind.rawValue
            item.target = self
            menu.addItem(item)
        }
        let item = NSMenuItem(title: "Peek", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func contextPeek(_ sender: NSMenuItem) {
        guard let kind = (sender.representedObject as? String).flatMap(PeekKind.init(rawValue:)) else { return }
        perform(kind.editorCommand)
    }

    // MARK: Brief messages

    private static let messageIdentifier = NSUserInterfaceItemIdentifier("omcInlineMessage")

    /// A short note below the line of `location` ("No definition found"), gone after a moment.
    func showInlineMessage(_ text: String, at location: Int) {
        guard let textView else { return }
        textView.subviews.filter { $0.identifier == Self.messageIdentifier }.forEach { $0.removeFromSuperview() }
        let length = document.textStorage.length
        let caret = rect(for: NSRange(location: min(location, length), length: 0)) ?? .zero
        let label = InlineMessageView(text: text)
        label.identifier = Self.messageIdentifier
        label.setFrameOrigin(NSPoint(x: max(textView.visibleRect.minX + 4, caret.minX - 4), y: caret.maxY + 2))
        textView.addSubview(label, positioned: .above, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak label] in label?.removeFromSuperview() }
    }

    /// The note shown now, if any.
    var inlineMessage: String? {
        (textView?.subviews.first { $0.identifier == Self.messageIdentifier } as? InlineMessageView)?.text
    }
}

/// The theme's colors for a peek.
@MainActor
private enum PeekColors {
    static var theme: EditorThemeDefinition { EditorTheme.current }
    static var background: NSColor { theme.background }
    /// The header and the list: the theme's panel color, or the background a shade off.
    static var chrome: NSColor { theme.chrome?.panel ?? .windowBackgroundColor }
    static var foreground: NSColor { theme.foreground }
    static var secondary: NSColor { theme.lineNumber }
    static var selection: NSColor { theme.selection }
    static var border: NSColor { NSColor.controlAccentColor }
}

/// The note "No definition found for ‘x’".
final class InlineMessageView: NSView {
    let text: String
    private let label: NSTextField

    init(text: String) {
        self.text = text
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = PeekColors.foreground
        addSubview(label)
        let size = label.fittingSize
        frame.size = NSSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
        label.frame = NSRect(x: 8, y: 4, width: ceil(size.width), height: ceil(size.height))
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = PeekColors.chrome.cgColor
        layer?.borderColor = PeekColors.border.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: The panel

/// The peek's view: a header (file, count, Open, Close), the small editor, and the list.
final class PeekPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let headerHeight: CGFloat = 24
    static let borderWidth: CGFloat = 2
    private static let listWidthFraction: CGFloat = 0.32

    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSelect: ((Int) -> Void)?
    var onMove: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let closeButton = NSButton()
    private let editorHost = NSView()
    private let listScroll = NSScrollView()
    let tableView = PeekTableView()

    /// The list's rows: a file's header, or a place (by its index in the model).
    enum Row: Equatable { case file(String, URL, Int), entry(Int) }
    private(set) var rows: [Row] = []
    private var entries: [PeekEntry] = []
    private var showsList = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        layer?.zPosition = 10
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        configure(openButton, symbol: "arrow.up.forward.square", help: "Open in Editor (↩)", action: #selector(openClicked))
        configure(closeButton, symbol: "xmark", help: "Close (Esc)", action: #selector(closeClicked))
        editorHost.autoresizesSubviews = true
        addSubview(editorHost)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("place"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = 20
        tableView.intercellSpacing = .zero
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onEnter = { [weak self] in self?.onOpen?() }
        tableView.onEscape = { [weak self] in self?.onClose?() }
        tableView.onMove = { [weak self] offset in self?.onMove?(offset) }
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        addSubview(listScroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: NSButton, symbol: String, help: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.target = self
        button.action = action
        addSubview(button)
    }

    override var isFlipped: Bool { true }

    // Clicks between the parts aren't the editor's below (they'd move its cursor).
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: Content

    func reload(_ model: PeekModel) {
        entries = model.entries
        showsList = model.showsList
        var rows: [Row] = []
        var index = 0
        for file in model.files {
            rows.append(.file(file.path, file.url, file.matches.count))
            for _ in file.matches {
                rows.append(.entry(index))
                index += 1
            }
        }
        self.rows = rows
        listScroll.isHidden = !showsList
        applyColors()
        tableView.reloadData()
        select(model.selection)
        needsLayout = true
        needsDisplay = true
    }

    func select(_ entry: Int) {
        guard let row = rows.firstIndex(of: .entry(entry)) else { return }
        if tableView.selectedRow != row { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        tableView.scrollRowToVisible(row)
    }

    func setHeader(entry: PeekEntry, model: PeekModel) {
        titleLabel.stringValue = entry.url.lastPathComponent
        let directory = (entry.path as NSString).deletingLastPathComponent
        let place = "line \(entry.match.line + 1)"
        detailLabel.stringValue = [directory, place, model.showsList ? model.countText : nil]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "  ·  ")
        needsLayout = true
    }

    func setEditorView(_ view: NSView) {
        editorHost.subviews.forEach { $0.removeFromSuperview() }
        view.frame = editorHost.bounds
        view.autoresizingMask = [.width, .height]
        editorHost.addSubview(view)
    }

    private func applyColors() {
        titleLabel.textColor = PeekColors.foreground
        detailLabel.textColor = PeekColors.secondary
        openButton.contentTintColor = PeekColors.secondary
        closeButton.contentTintColor = PeekColors.secondary
        tableView.backgroundColor = PeekColors.chrome
    }

    // MARK: Layout and drawing

    private var listWidth: CGFloat {
        showsList ? min(380, max(200, (bounds.width * Self.listWidthFraction).rounded())) : 0
    }

    override func layout() {
        super.layout()
        let border = Self.borderWidth, header = Self.headerHeight
        let buttonSize: CGFloat = 20
        closeButton.frame = NSRect(x: bounds.width - buttonSize - 6, y: border + (header - buttonSize) / 2, width: buttonSize, height: buttonSize)
        openButton.frame = closeButton.frame.offsetBy(dx: -buttonSize - 2, dy: 0)
        let titleWidth = min(ceil(titleLabel.fittingSize.width), max(0, openButton.frame.minX - 20))
        let labelHeight = ceil(titleLabel.fittingSize.height)
        titleLabel.frame = NSRect(x: 10, y: border + (header - labelHeight) / 2, width: titleWidth, height: labelHeight)
        let detailHeight = ceil(detailLabel.fittingSize.height)
        let detailX = titleLabel.frame.maxX + 8
        detailLabel.frame = NSRect(x: detailX, y: border + (header - detailHeight) / 2 + 0.5,
                                   width: max(0, openButton.frame.minX - 8 - detailX), height: detailHeight)
        let bodyTop = border + header
        let bodyHeight = max(0, bounds.height - bodyTop - border)
        let list = listWidth
        editorHost.frame = NSRect(x: 0, y: bodyTop, width: max(0, bounds.width - list - (showsList ? 1 : 0)), height: bodyHeight)
        listScroll.frame = NSRect(x: bounds.width - list, y: bodyTop, width: list, height: bodyHeight)
        tableView.tableColumns.first?.width = max(0, list - 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        PeekColors.background.setFill()
        bounds.fill()
        let border = Self.borderWidth
        PeekColors.chrome.setFill()
        NSRect(x: 0, y: border, width: bounds.width, height: Self.headerHeight).fill()
        if showsList { NSRect(x: bounds.width - listWidth, y: border, width: listWidth, height: bounds.height - 2 * border).fill() }
        PeekColors.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: border).fill()
        NSRect(x: 0, y: bounds.height - border, width: bounds.width, height: border).fill()
        PeekColors.secondary.withAlphaComponent(0.25).setFill()
        NSRect(x: 0, y: border + Self.headerHeight - 1, width: bounds.width, height: 1).fill()
        if showsList {
            NSRect(x: bounds.width - listWidth - 1, y: border + Self.headerHeight, width: 1,
                   height: max(0, bounds.height - Self.headerHeight - 2 * border)).fill()
        }
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .entry = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PeekRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("peekCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.attributedStringValue = text(of: rows[row])
        return cell
    }

    private func text(of row: Row) -> NSAttributedString {
        switch row {
        case .file(let path, let url, let count):
            let result = NSMutableAttributedString(string: url.lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: PeekColors.foreground])
            let directory = (path as NSString).deletingLastPathComponent
            result.append(NSAttributedString(string: (directory.isEmpty ? "" : "  " + directory) + "  \(count)", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: PeekColors.secondary]))
            return result
        case .entry(let index):
            let match = entries[index].match
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let (preview, trimmed) = match.preview.trimmingLeadingWhitespace()
            let result = NSMutableAttributedString(string: "  \(match.line + 1)  ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: PeekColors.secondary])
            let line = NSMutableAttributedString(string: preview, attributes: [.font: font, .foregroundColor: PeekColors.foreground])
            let highlight = NSRange(location: match.previewRange.location - trimmed, length: match.previewRange.length)
            if highlight.location >= 0, NSMaxRange(highlight) <= line.length {
                line.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)], range: highlight)
            }
            result.append(line)
            return result
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard rows.indices.contains(row), case .entry(let index) = rows[row] else { return }
        onSelect?(index)
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row), case .entry = rows[row] else { return }
        onOpen?()
    }

    @objc private func openClicked() { onOpen?() }
    @objc private func closeClicked() { onClose?() }
}

private extension String {
    /// Without its leading spaces and tabs (the list shows the code, not its indentation).
    func trimmingLeadingWhitespace() -> (string: String, dropped: Int) {
        let dropped = prefix { $0 == " " || $0 == "\t" }.count
        return (String(dropFirst(dropped)), dropped)
    }
}

/// The list, with ↩ (open), Esc (close) and ↑↓ (the previous or next place, past the files'
/// rows, wrapping around).
final class PeekTableView: NSTableView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onMove: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 36, 76: onEnter?()
        case 53: onEscape?()
        case 125: onMove?(1)
        case 126: onMove?(-1)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// A list row selected in the theme's selection color.
private final class PeekRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        PeekColors.selection.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}
