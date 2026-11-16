import AppKit
import SwiftUI

/// Find in Files results as a table: a row per file and per match, made only for the rows in
/// view, of plain AppKit views. A SwiftUI `List` compared and laid out every row at each update
/// of a running search: 70–90 ms of the main thread per update at 20,000 results (ten a
/// second), against 2–7 ms here. SwiftUI rows in a table still took 20 ms to lay out.
struct SearchResultsTable: NSViewRepresentable {
    let results: [SearchFileResult]
    /// The replacement text, when replacing: rows show what their match becomes.
    let replacement: String?
    let replacementPreview: @MainActor (SearchMatch) -> String
    let onOpen: @MainActor (SearchFileResult, SearchMatch) -> Void
    let onReplaceFile: @MainActor (SearchFileResult) -> Void
    let onReplaceMatch: @MainActor (SearchFileResult, SearchMatch) -> Void

    static let rowHeight: CGFloat = 22

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))
        table.setAccessibilityLabel("Search results")
        context.coordinator.table = table

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private var source: SearchResultsTable?
        /// A file's row (`match` -1) or one of its matches', for each row.
        private(set) var rows: [(file: Int32, match: Int32)] = []
        /// Files whose matches are hidden (by path, so they stay hidden as results come in).
        private(set) var collapsed: Set<String> = []

        func update(_ source: SearchResultsTable) {
            self.source = source
            rebuild()
        }

        private func rebuild() {
            guard let source else { return }
            var rows: [(file: Int32, match: Int32)] = []
            rows.reserveCapacity(source.results.count + source.results.reduce(0) { $0 + $1.matches.count })
            for (fileIndex, result) in source.results.enumerated() {
                rows.append((Int32(fileIndex), -1))
                guard !collapsed.contains(result.path) else { continue }
                for matchIndex in result.matches.indices { rows.append((Int32(fileIndex), Int32(matchIndex))) }
            }
            let before = self.rows.count
            self.rows = rows
            guard let table else { return }
            // Most rows gone (a new search): removing them one by one took 13 ms at 20,000.
            if rows.count < before / 2 { return table.reloadData() }
            // The rows that have views (those in view, and a few around) are shown again in
            // the views they have: `reloadData` made new ones for them each time (most of an
            // update). A row now of the other kind (a file's where a match's was) is made again.
            table.noteNumberOfRowsChanged()
            var remade = IndexSet()
            table.enumerateAvailableRowViews { rowView, row in
                guard let cell = rowView.view(atColumn: 0) as? NSView else { return }
                if !configure(cell, row: row) { remade.insert(row) }
            }
            if !remade.isEmpty { table.reloadData(forRowIndexes: remade, columnIndexes: [0]) }
        }

        /// Shows the row in `cell`; false if it's the wrong kind of cell for it.
        @discardableResult
        private func configure(_ cell: NSView, row: Int) -> Bool {
            guard let source, let (result, match) = entry(at: row) else { return false }
            let replacing = source.replacement != nil
            guard let match else {
                guard let cell = cell as? SearchFileCell else { return false }
                cell.show(result, isCollapsed: collapsed.contains(result.path),
                          onReplace: replacing ? { source.onReplaceFile(result) } : nil)
                return true
            }
            guard let cell = cell as? SearchMatchCell else { return false }
            cell.show(match, replacement: replacing ? source.replacementPreview(match) : nil,
                      onReplace: replacing ? { source.onReplaceMatch(result, match) } : nil)
            return true
        }

        /// The file and match (nil for a file's row) a row shows.
        func entry(at row: Int) -> (SearchFileResult, SearchMatch?)? {
            guard let source, rows.indices.contains(row) else { return nil }
            let entry = rows[row]
            let result = source.results[Int(entry.file)]
            return (result, entry.match < 0 ? nil : result.matches[Int(entry.match)])
        }

        /// A click: a match opens, a file's row shows or hides its matches.
        @objc func clicked(_ sender: NSTableView) {
            activate(row: sender.clickedRow)
        }

        func activate(row: Int) {
            guard let source, let (result, match) = entry(at: row) else { return }
            if let match {
                source.onOpen(result, match)
            } else {
                if collapsed.remove(result.path) == nil { collapsed.insert(result.path) }
                rebuild()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let cell: NSView = rows[row].match < 0
                ? reuse(tableView, "file") { SearchFileCell(frame: .zero) }
                : reuse(tableView, "match") { SearchMatchCell(frame: .zero) }
            configure(cell, row: row)
            return cell
        }

        private func reuse<Cell: NSTableCellView>(_ tableView: NSTableView, _ name: String, make: () -> Cell) -> Cell {
            let identifier = NSUserInterfaceItemIdentifier(name)
            if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell { return cell }
            let cell = make()
            cell.identifier = identifier
            return cell
        }
    }
}

/// A row with a button that shows while the pointer is over it.
class HoverCell: NSTableCellView {
    let button: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.imagePosition = .imageOnly
        button.isHidden = true
        return button
    }()
    private var onButton: (() -> Void)?
    private var isHovered = false { didSet { updateButton(); needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.target = self
        button.action = #selector(pressed)
        addSubview(button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The button's look.
    func setButton(_ symbol: String, help: String) {
        button.image = Self.symbol(symbol, help)
        button.toolTip = help
    }

    /// A symbol image, looked up by name once (rows are made a screenful at a time).
    static func symbol(_ name: String, _ description: String?) -> NSImage? {
        if let image = symbols[name] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        symbols[name] = image
        return image
    }
    private static var symbols: [String: NSImage] = [:]

    /// What the button does; nil hides it.
    func setButtonAction(_ action: (() -> Void)?) {
        onButton = action
        updateButton()
    }

    private func updateButton() { button.isHidden = !(isHovered && onButton != nil) }

    @objc private func pressed() { onButton?() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    /// The button at the right of `bounds`, if shown; returns the x it leaves free.
    func layoutButton(right: CGFloat) -> CGFloat {
        guard !button.isHidden else { return right }
        let size: CGFloat = 18
        button.frame = NSRect(x: right - size, y: (bounds.height - size) / 2, width: size, height: size)
        return right - size - 4
    }

    static func label(_ font: NSFont, color: NSColor = .labelColor, truncation: NSLineBreakMode = .byTruncatingTail) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = truncation
        field.cell?.truncatesLastVisibleLine = true
        field.maximumNumberOfLines = 1
        return field
    }
}

/// A file's row: chevron, name, folder, match count.
final class SearchFileCell: HoverCell {
    private let chevron = NSImageView()
    private let icon = NSImageView(image: HoverCell.symbol("doc.text", nil) ?? NSImage())
    private let name = HoverCell.label(.systemFont(ofSize: NSFont.systemFontSize))
    private let folder = HoverCell.label(.systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor,
                                         truncation: .byTruncatingHead)
    private let count = SearchCountBadge()

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        icon.contentTintColor = .secondaryLabelColor
        for view in [chevron, icon, name, folder, count] as [NSView] { addSubview(view) }
        setButton("text.badge.checkmark", help: "Replace All in File")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let collapsedImage = HoverCell.symbol("chevron.right", "Show matches")
    private static let expandedImage = HoverCell.symbol("chevron.down", "Hide matches")

    /// What the row shows: when it shows it already, nothing is set (or drawn) again.
    private var shown: (path: String, count: Int, isCollapsed: Bool)?

    func show(_ result: SearchFileResult, isCollapsed: Bool, onReplace: (() -> Void)?) {
        setButtonAction(onReplace)
        if let shown, shown == (result.path, result.matches.count, isCollapsed) { return }
        shown = (result.path, result.matches.count, isCollapsed)
        chevron.image = isCollapsed ? Self.collapsedImage : Self.expandedImage
        name.stringValue = (result.path as NSString).lastPathComponent
        folder.stringValue = (result.path as NSString).deletingLastPathComponent
        count.text = "\(result.matches.count)"
        setAccessibilityLabel("\(result.path), \(result.matches.count) matches")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        chevron.frame = NSRect(x: 4, y: 0, width: 14, height: height)
        icon.frame = NSRect(x: 20, y: (height - 16) / 2, width: 16, height: 16)
        var right = bounds.width - 4
        let badge = count.fittingSize
        count.frame = NSRect(x: right - badge.width, y: (height - badge.height) / 2, width: badge.width, height: badge.height)
        right = layoutButton(right: count.frame.minX - 4)
        let x = icon.frame.maxX + 6
        let nameSize = name.fittingSize
        name.frame = NSRect(x: x, y: (height - nameSize.height) / 2, width: min(nameSize.width, max(0, right - x)), height: nameSize.height)
        let folderX = name.frame.maxX + 6
        folder.frame = NSRect(x: folderX, y: (height - Self.folderHeight) / 2, width: max(0, right - folderX), height: Self.folderHeight)
    }

    private static let folderHeight = ceil(HoverCell.label(.systemFont(ofSize: NSFont.smallSystemFontSize)).fittingSize.height)
}

/// A match's line, the match highlighted (or shown replaced).
final class SearchMatchCell: HoverCell {
    private let line = HoverCell.label(.monospacedSystemFont(ofSize: 12, weight: .regular))

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(line)
        setButton("checkmark.circle", help: "Replace")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What the row shows: when it shows it already, nothing is set (or drawn) again.
    private var shown: (match: SearchMatch, replacement: String?)?

    func show(_ match: SearchMatch, replacement: String?, onReplace: (() -> Void)?) {
        setButtonAction(onReplace)
        if let shown, shown.match == match, shown.replacement == replacement { return }
        shown = (match, replacement)
        line.attributedStringValue = Self.text(match, replacement: replacement)
        toolTip = "Line \(match.line + 1)"
        needsLayout = true
    }

    private static let lineHeight = ceil(HoverCell.label(.monospacedSystemFont(ofSize: 12, weight: .bold)).fittingSize.height)

    override func layout() {
        super.layout()
        let right = layoutButton(right: bounds.width - 4)
        let height = Self.lineHeight
        line.frame = NSRect(x: 24, y: (bounds.height - height) / 2, width: max(0, right - 24), height: height)
    }

    /// The line with the match in bold on orange, or struck out in red with the replacement in green.
    static func text(_ match: SearchMatch, replacement: String?) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let preview = match.preview as NSString
        let range = match.previewRange
        let text = NSMutableAttributedString(string: match.preview, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        guard range.location >= 0, NSMaxRange(range) <= preview.length else { return text }
        guard let replacement else {
            text.addAttributes([.font: bold, .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.35)], range: range)
            return text
        }
        text.addAttributes([.font: bold, .backgroundColor: NSColor.systemRed.withAlphaComponent(0.25),
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: range)
        text.insert(NSAttributedString(string: replacement.replacingOccurrences(of: "\n", with: "⏎"), attributes: [
            .font: bold, .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.3),
        ]), at: NSMaxRange(range))
        return text
    }
}

/// The number of matches in a capsule.
final class SearchCountBadge: NSView {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: Self.attributes)
        return NSSize(width: ceil(size.width) + 10, height: ceil(size.height) + 2)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = (text as NSString).size(withAttributes: Self.attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: Self.attributes)
    }
}
