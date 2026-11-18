import AppKit

extension NSAttributedString.Key {
    /// On the character before a color literal: its swatch (a `ColorSwatchMark`). With a `.kern`
    /// that opens the gap it's drawn in, as inlay hints do. Layout only: the text doesn't change.
    static let omcColorSwatch = NSAttributedString.Key("omcColorSwatch")
}

/// A color swatch as kept in the text (attributes move with the text as it's edited).
final class ColorSwatchMark: NSObject {
    let color: RGBAColor
    /// The literal's length: it starts right after the marked character.
    let length: Int
    /// The language server found it (it's rewritten by its color presentations).
    let fromServer: Bool

    init(color: RGBAColor, length: Int, fromServer: Bool) {
        self.color = color
        self.length = length
        self.fromServer = fromServer
    }

    func isSame(as other: ColorSwatchMark) -> Bool {
        length == other.length && fromServer == other.fromServer && color.isClose(to: other.color)
    }
}

@MainActor
enum ColorSwatchStyle {
    /// The swatch's side: a little smaller than a capital letter.
    static var size: CGFloat { max(7, (EditorTheme.font.capHeight + 2).rounded()) }
    /// The gap it takes: the swatch with a little room on each side.
    static var width: CGFloat { size + 6 }
}

/// What a document knows about its swatches between refreshes.
@MainActor
final class ColorDecoratorState {
    var task: Task<Void, Never>?
    /// The server's colors for a version of the text (`editVersion`).
    var serverColors: (version: Int, colors: [LSPColorInformation])?
    /// An edit since the server was last asked.
    var needsServer = true
}

// MARK: Language server

struct LSPColorInformation: Equatable, Sendable {
    var range: LSPRange
    var color: RGBAColor

    init(range: LSPRange, color: RGBAColor) {
        self.range = range
        self.color = color
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let range = LSPRange(json: object["range"]),
              let color = Self.color(object["color"]) else { return nil }
        self.init(range: range, color: color)
    }

    static func color(_ json: Any?) -> RGBAColor? {
        guard let object = json as? [String: Any], let red = (object["red"] as? NSNumber)?.doubleValue,
              let green = (object["green"] as? NSNumber)?.doubleValue, let blue = (object["blue"] as? NSNumber)?.doubleValue
        else { return nil }
        return RGBAColor(red: red, green: green, blue: blue, alpha: (object["alpha"] as? NSNumber)?.doubleValue ?? 1)
    }

    static func json(_ color: RGBAColor) -> [String: Any] {
        ["red": color.red, "green": color.green, "blue": color.blue, "alpha": color.alpha]
    }
}

struct LSPColorPresentation: Equatable, Sendable {
    var label: String
    var textEdit: LSPTextEdit?

    init?(json: Any?) {
        guard let object = json as? [String: Any], let label = object["label"] as? String else { return nil }
        self.label = label
        textEdit = LSPTextEdit(json: object["textEdit"])
    }
}

extension LanguageClient {
    /// Every color in the file (`textDocument/documentColor`).
    func documentColors(url: URL) async throws -> [LSPColorInformation] {
        let result = try await request("textDocument/documentColor", params: ["textDocument": ["uri": url.absoluteString]])
        return (result as? [Any] ?? []).compactMap(LSPColorInformation.init(json:))
    }

    /// Ways to write `color` in place of the one at `range` (`textDocument/colorPresentation`).
    func colorPresentations(url: URL, color: RGBAColor, range: LSPRange) async throws -> [LSPColorPresentation] {
        let result = try await request("textDocument/colorPresentation", params: [
            "textDocument": ["uri": url.absoluteString], "color": LSPColorInformation.json(color), "range": range.json,
        ])
        return (result as? [Any] ?? []).compactMap(LSPColorPresentation.init(json:))
    }
}

// MARK: Finding and showing swatches

extension EditorDocument {
    var showsColorDecorators: Bool { projectSettings.showsColorDecorators ?? AppSettings.shared.showsColorDecorators }

    /// The swatches shown now (tests): the literal each is before, and its color.
    var shownColorSwatches: [(range: NSRange, color: RGBAColor, fromServer: Bool)] {
        var swatches: [(NSRange, RGBAColor, Bool)] = []
        textStorage.enumerateAttribute(.omcColorSwatch, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let mark = value as? ColorSwatchMark {
                swatches.append((NSRange(location: range.location + 1, length: mark.length), mark.color, mark.fromServer))
            }
        }
        return swatches
    }

    /// Looks for the colors in view again (after `delay`, restarted by every call). After an
    /// edit (`edited`), the language server is asked again too, if it knows colors.
    func refreshColorDecorators(after delay: Duration = .zero, edited: Bool = true) {
        Self.observeScrolling()
        let state = colorDecorators
        if edited { state.needsServer = true }
        state.task?.cancel()
        state.task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            guard self.showsColorDecorators else {
                state.serverColors = nil
                self.applyColorSwatches(nil, in: [NSRange(location: 0, length: self.textStorage.length)])
                return
            }
            if let client = self.readyLanguageClient, client.supports(.color) {
                if state.needsServer || state.serverColors == nil {
                    state.needsServer = false
                    let version = self.editVersion
                    let colors = try? await client.documentColors(url: self.url)
                    guard !Task.isCancelled else { return }
                    if let colors, version == self.editVersion { state.serverColors = (version, colors) }
                }
            } else {
                state.serverColors = nil
            }
            self.applyColorSwatches()
        }
    }

    /// Waits for the refresh in progress (tests).
    func waitForColorDecorators() async { await colorDecorators.task?.value }

    /// Scrolling shows other lines: their colors are looked for (one observer for every editor).
    private static var isObservingScrolling = false

    private static func observeScrolling() {
        guard !isObservingScrolling else { return }
        isObservingScrolling = true
        NotificationCenter.default.addObserver(forName: EditorController.didScrollNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let editor = note.object
            MainActor.assumeIsolated {
                (editor as? EditorController)?.document.refreshColorDecorators(after: .milliseconds(60), edited: false)
            }
        }
    }

    /// What the editors show, as whole lines (merged; a few screens at most).
    func colorScanRanges() -> [NSRange] {
        let length = textStorage.length
        var ranges: [NSRange] = []
        for editor in editors where !editor.isParked && editor.textView != nil {
            guard let visible = editor.visibleCharacterRange() else { continue }
            ranges.append(visible)
        }
        if ranges.isEmpty { ranges = [NSRange(location: 0, length: min(length, 20_000))] }
        let index = lineIndex
        var lines: [NSRange] = ranges.map { range in
            let first = index.line(containing: min(range.location, length))
            let last = index.line(containing: min(NSMaxRange(range), length))
            let start = index.lineStarts[first]
            let end = last + 1 < index.lineCount ? index.lineStarts[last + 1] : length
            return NSRange(location: start, length: min(end - start, ColorLiterals.scanLimit))
        }
        lines.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in lines {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The colors in view now: the server's when it knows them (and they're for this text),
    /// and the ones found in the text that no color of the server's overlaps. (Servers know
    /// fewer formats: SourceKit-LSP only `#colorLiteral`, which would hide every `Color(…)`.)
    func applyColorSwatches() {
        let ranges = colorScanRanges()
        var swatches: [Int: ColorSwatchMark] = [:]
        var serverRanges: [NSRange] = []
        let text = textStorage.mutableString
        let state = colorDecorators
        if readyLanguageClient?.supports(.color) == true, let server = state.serverColors {
            // An edit since: the swatches move with the text until the server's next answer.
            guard server.version == editVersion else { return }
            for info in server.colors {
                let range = range(for: info.range)
                guard range.length > 0, range.location > 0, text.character(at: range.location - 1) != 0x0A,
                      ranges.contains(where: { NSLocationInRange(range.location, $0) }) else { continue }
                swatches[range.location - 1] = ColorSwatchMark(color: info.color, length: range.length, fromServer: true)
                serverRanges.append(range)
            }
        }
        if let syntax = ColorSyntax.of(language) {
            for range in ranges {
                for literal in ColorLiterals.find(in: text, range: range, syntax: syntax)
                where !serverRanges.contains(where: { NSIntersectionRange($0, literal.range).length > 0 }) {
                    swatches[literal.range.location - 1] = ColorSwatchMark(color: literal.color, length: literal.range.length, fromServer: false)
                }
            }
        }
        applyColorSwatches(swatches, in: ranges)
    }

    /// Makes `ranges` show `swatches` (by the index of the character before each literal; nil:
    /// none). Only the differences are written: attribute changes make TextKit lay text out again.
    func applyColorSwatches(_ swatches: [Int: ColorSwatchMark]?, in ranges: [NSRange]) {
        var wanted = swatches ?? [:]
        let width = ColorSwatchStyle.width
        var stale: [NSRange] = []
        let whole = NSRange(location: 0, length: textStorage.length)
        for range in ranges {
            textStorage.enumerateAttribute(.omcColorSwatch, in: NSIntersectionRange(range, whole)) { value, attributeRange, _ in
                guard let shown = value as? ColorSwatchMark else { return }
                for index in attributeRange.location..<NSMaxRange(attributeRange) {
                    let kern = textStorage.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat
                    if let mark = wanted[index], mark.isSame(as: shown), kern == width {
                        wanted[index] = nil // already shown
                    } else {
                        stale.append(NSRange(location: index, length: 1))
                    }
                }
            }
        }
        // Where an inlay hint or a suggestion has its own gap: not there.
        for index in wanted.keys where index >= textStorage.length
            || textStorage.attribute(.omcInlayHint, at: index, effectiveRange: nil) != nil
            || textStorage.attribute(.omcGhostGap, at: index, effectiveRange: nil) != nil {
            wanted[index] = nil
        }
        guard !stale.isEmpty || !wanted.isEmpty else { return }
        // Layout attributes only: the document's edit observer ignores them (no LSP change,
        // not dirty, nothing to undo).
        textStorage.beginEditing()
        for range in stale {
            textStorage.removeAttribute(.omcColorSwatch, range: range)
            if textStorage.attribute(.omcInlayHint, at: range.location, effectiveRange: nil) == nil,
               textStorage.attribute(.omcGhostGap, at: range.location, effectiveRange: nil) == nil {
                textStorage.removeAttribute(.kern, range: range)
            }
        }
        for (index, mark) in wanted {
            textStorage.addAttributes([.omcColorSwatch: mark, .kern: width], range: NSRange(location: index, length: 1))
        }
        textStorage.endEditing()
        // Without word wrap the text view is as wide as the widest line plus this room.
        var perLine: [Int: CGFloat] = [:]
        for index in wanted.keys { perLine[lineIndex.line(containing: index), default: 0] += width }
        let widest = perLine.values.max() ?? 0
        let widthChanged = widest > widestInlayHints
        if widthChanged { widestInlayHints = widest }
        editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true }
        if widthChanged { editors.forEach { $0.updateTextWidth() } }
    }
}

extension EditorController {
    /// The swatches in view: where each is drawn, and the character it's on.
    func colorSwatchRects() -> [(rect: NSRect, mark: ColorSwatchMark, index: Int)] {
        guard let range = visibleCharacterRange() else { return [] }
        let storage = document.textStorage
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        var result: [(NSRect, ColorSwatchMark, Int)] = []
        let size = ColorSwatchStyle.size, width = ColorSwatchStyle.width
        storage.enumerateAttribute(.omcColorSwatch, in: clipped) { value, attributeRange, _ in
            guard let mark = value as? ColorSwatchMark, NSMaxRange(attributeRange) < storage.length else { return }
            // The gap ends where the literal's first glyph starts. (TextKit splits the gap between
            // the two characters' segments: the literal's starts mid-gap, its glyph is at its end.)
            let literal = NSMaxRange(attributeRange)
            guard let next = laidOutRect(ofCharacterAt: literal) ?? rect(for: NSRange(location: literal, length: 1)) else { return }
            let character = storage.mutableString.substring(with: NSRange(location: literal, length: 1)) as NSString
            let font = storage.attribute(.font, at: literal, effectiveRange: nil) as? NSFont ?? EditorTheme.font
            let gapEnd = next.maxX - character.size(withAttributes: [.font: font]).width
            let x = gapEnd - width + (width - size) / 2
            result.append((NSRect(x: x.rounded(), y: (next.midY - size / 2).rounded(), width: size, height: size), mark, attributeRange.location))
        }
        return result
    }

    /// A click on a swatch: the color panel opens with its color.
    func handleColorSwatchClick(at point: NSPoint) -> Bool {
        guard let hit = colorSwatchRects().first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) else { return false }
        return ColorPickerSession.begin(editor: self, index: hit.index, mark: hit.mark) != nil
    }

    /// Draws the swatches (in the overlay).
    static func drawColorSwatch(_ color: RGBAColor, in rect: NSRect, border: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if !color.isOpaque {
            // A checkerboard under it shows how see-through it is.
            NSColor.white.setFill()
            rect.fill()
            NSColor(white: 0.75, alpha: 1).setFill()
            let half = rect.width / 2
            NSRect(x: rect.minX, y: rect.minY, width: half, height: half).fill()
            NSRect(x: rect.minX + half, y: rect.minY + half, width: rect.width - half, height: rect.height - half).fill()
        }
        color.nsColor.setFill()
        rect.fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
        border.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.stroke()
    }
}

// MARK: Picking a color

/// The color panel editing one literal: each change rewrites it in its format. A drag in the
/// panel is one undo step (the step ends when the mouse is let go); closing the panel or
/// moving the cursor off the literal ends the session.
@MainActor
final class ColorPickerSession: NSObject {
    private(set) static var current: ColorPickerSession?
    /// Tests: no panel (they send colors with `change(to:)`).
    static var showsPanel = true

    private(set) weak var editor: EditorController?
    private weak var document: EditorDocument?
    /// The literal now.
    private(set) var range: NSRange
    /// The literal when picking started: its format is kept.
    let original: String
    let fromServer: Bool
    /// Whether the panel is being dragged in (a step goes on until it isn't).
    var isDragging: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    /// The text before the step's first change (restored, then replaced as one undoable edit).
    private var stepStart: (range: NSRange, text: String)?
    private var expectedVersion: Int
    private var commitTask: Task<Void, Never>?
    private var pendingColor: RGBAColor?
    private var isAsking = false
    private var isEditing = false
    private var isSettingPanel = false
    private var ownsPanel = false
    private var observers: [NSObjectProtocol] = []

    private init(editor: EditorController, range: NSRange, original: String, fromServer: Bool) {
        self.editor = editor
        document = editor.document
        self.range = range
        self.original = original
        self.fromServer = fromServer
        expectedVersion = editor.document.editVersion
    }

    /// Starts picking for the swatch on character `index` (ending any session before).
    @discardableResult
    static func begin(editor: EditorController, index: Int, mark: ColorSwatchMark) -> ColorPickerSession? {
        current?.detach()
        let document = editor.document
        let range = NSRange(location: index + 1, length: mark.length)
        guard NSMaxRange(range) <= document.textStorage.length else { return nil }
        let text = document.textStorage.mutableString.substring(with: range)
        guard mark.fromServer || ColorLiterals.color(of: text) != nil else { return nil }
        let session = ColorPickerSession(editor: editor, range: range, original: text, fromServer: mark.fromServer)
        current = session
        // The cursor goes to the literal: moving it away ends picking.
        editor.textView.setSelectedRange(NSRange(location: range.location, length: 0))
        session.observers.append(NotificationCenter.default.addObserver(
            forName: EditorController.selectionDidChangeNotification, object: editor, queue: .main) { [weak session] _ in
            MainActor.assumeIsolated { session?.selectionChanged() }
        })
        if showsPanel {
            let panel = NSColorPanel.shared
            panel.showsAlpha = true
            panel.isContinuous = true
            session.isSettingPanel = true
            panel.color = mark.color.nsColor
            session.isSettingPanel = false
            panel.setTarget(session)
            panel.setAction(#selector(panelColorChanged(_:)))
            session.ownsPanel = true
            session.observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak session] _ in
                MainActor.assumeIsolated { session?.detach() }
            })
            panel.orderFront(nil)
        }
        return session
    }

    @objc private func panelColorChanged(_ sender: NSColorPanel) {
        guard !isSettingPanel, let color = RGBAColor(sender.color) else { return }
        change(to: color)
    }

    private func selectionChanged() {
        guard !isEditing, let editor, editor.textView != nil else { return }
        let selection = editor.textView.selectedRange()
        if selection.location < range.location || NSMaxRange(selection) > NSMaxRange(range) { detach() }
    }

    /// The panel's color changed: the literal is rewritten.
    func change(to color: RGBAColor) {
        guard let document, editor != nil else { return detach() }
        if document.editVersion != expectedVersion {
            // Edited by something else: a literal of ours is looked for where it was.
            guard !fromServer, relocate(in: document) else { return detach() }
        }
        if fromServer {
            pendingColor = color
            askServer()
            return
        }
        guard let text = ColorLiterals.rewrite(original, to: color) else { return }
        replace(TextReplacement(range: range, text: text))
        stepChanged()
    }

    private func relocate(in document: EditorDocument) -> Bool {
        let text = document.textStorage.mutableString
        guard range.location < text.length, let syntax = ColorSyntax.of(document.language) else { return false }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        guard let literal = ColorLiterals.find(in: text, range: line, syntax: syntax).first(where: { $0.range.location == range.location })
        else { return false }
        range = literal.range
        stepStart = nil // that edit ended the step
        expectedVersion = document.editVersion
        return true
    }

    /// Asks the server how to write the latest color (one request at a time: a drag sends
    /// many colors, and only the last one matters).
    private func askServer() {
        guard !isAsking, let color = pendingColor, let document, let client = document.readyLanguageClient else { return }
        pendingColor = nil
        isAsking = true
        let version = document.editVersion
        let lspRange = LSPRange(start: document.lspPosition(at: range.location), end: document.lspPosition(at: NSMaxRange(range)))
        Task { [weak self] in
            let presentations = try? await client.colorPresentations(url: document.url, color: color, range: lspRange)
            guard let self else { return }
            self.isAsking = false
            guard Self.current === self, version == document.editVersion, let first = presentations?.first else {
                if Self.current === self, version != document.editVersion { self.detach() }
                return
            }
            let edit = first.textEdit.map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) }
                ?? TextReplacement(range: self.range, text: first.label)
            self.replace(edit)
            if self.pendingColor != nil { self.askServer() } else { self.stepChanged() }
        }
    }

    /// Replaces the literal without an undo step (the step's end makes one for all of it).
    private func replace(_ edit: TextReplacement) {
        guard let document, NSMaxRange(edit.range) <= document.textStorage.length else { return }
        let text = document.textStorage.mutableString
        if stepStart == nil { stepStart = (edit.range, text.substring(with: edit.range)) }
        guard text.substring(with: edit.range) != edit.text else { return }
        isEditing = true
        defer { isEditing = false }
        Self.replaceWithoutUndo(edit, in: document)
        range = NSRange(location: edit.range.location, length: (edit.text as NSString).length)
        expectedVersion = document.editVersion
    }

    private static func replaceWithoutUndo(_ edit: TextReplacement, in document: EditorDocument) {
        let delta = (edit.text as NSString).length - edit.range.length
        let selections = document.editors.compactMap { editor in editor.textView.map { ($0, $0.selectedRange()) } }
        document.editors.forEach { $0.textWillChange() }
        document.undoManager.disableUndoRegistration()
        document.replaceCharacters([edit])
        document.undoManager.enableUndoRegistration()
        for (textView, selection) in selections {
            var location = selection.location
            if location >= NSMaxRange(edit.range) { location += delta } else if location > edit.range.location { location = edit.range.location }
            textView.setSelectedRange(NSRange(location: min(max(0, location), document.textStorage.length), length: 0))
        }
        document.editors.forEach { $0.textDidChangeProgrammatically() }
    }

    /// After a change: the step ends now, or once the drag does.
    private func stepChanged() {
        guard isDragging() else { return commit() }
        guard commitTask == nil else { return }
        commitTask = Task { [weak self] in
            while let self, self.isDragging() {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            self?.commitTask = nil
            self?.commit()
        }
    }

    /// Ends the step: what it changed becomes one undoable edit.
    func commit() {
        commitTask?.cancel()
        commitTask = nil
        guard let start = stepStart, let document else { return }
        stepStart = nil
        let text = document.textStorage.mutableString
        guard NSMaxRange(range) <= text.length else { return }
        let final = text.substring(with: range)
        guard final != start.text else { return }
        isEditing = true
        defer { isEditing = false }
        Self.replaceWithoutUndo(TextReplacement(range: range, text: start.text), in: document)
        range = NSRange(location: range.location, length: (start.text as NSString).length)
        _ = try? document.apply([TextReplacement(range: range, text: final)], actionName: "Change Color")
        range.length = (final as NSString).length
        expectedVersion = document.editVersion
    }

    /// Stops listening to the panel (and ends the step).
    func detach() {
        commit()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if ownsPanel {
            ownsPanel = false
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
        if Self.current === self { Self.current = nil }
    }
}
