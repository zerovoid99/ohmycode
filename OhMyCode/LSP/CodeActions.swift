import AppKit

extension Workspace {
    /// The diagnostics a range touches (the cursor's line when it's empty).
    func diagnostics(in document: EditorDocument, range: NSRange) -> [Diagnostic] {
        let lines = document.lineIndex
        let first = lines.line(containing: range.location), last = lines.line(containing: NSMaxRange(range))
        return document.diagnostics.filter { $0.range.start.line <= last && $0.range.end.line >= first }
    }

    /// The server's fixes and refactorings for `range` (quick fixes first, preferred first).
    func codeActions(for document: EditorDocument, range: NSRange, only: [String]? = nil) async -> [CodeAction] {
        guard let client = document.languageClient, client.state == .ready, client.supports(.codeAction) else { return [] }
        let lspRange = LSPRange(start: document.lspPosition(at: range.location), end: document.lspPosition(at: NSMaxRange(range)))
        let problems = diagnostics(in: document, range: range)
        var actions = (try? await client.codeActions(url: document.url, range: lspRange, diagnostics: problems, only: only)) ?? []
        // Fixes some servers put in the diagnostics themselves (SourceKit-LSP's fix-its).
        for diagnostic in problems {
            for fix in (diagnostic.json["codeActions"] as? [Any] ?? []).compactMap(CodeAction.init(json:))
            where !actions.contains(fix) && (only.map { kinds in kinds.contains { fix.kind.hasPrefix($0) } } ?? true) {
                actions.append(fix)
            }
        }
        func rank(_ action: CodeAction) -> Int {
            (action.isQuickFix ? 0 : action.isRefactor ? 2 : action.isSource ? 3 : 4) - (action.isPreferred ? 1 : 0)
        }
        return actions.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Runs an action: its edit (filled in by the server first if it sends them later), then
    /// its command (which may change files through `workspace/applyEdit`).
    func run(_ action: CodeAction, in document: EditorDocument) async {
        if let reason = action.disabledReason {
            errorMessage = "“\(action.title)” can't be applied: \(reason)"
            return
        }
        guard let client = document.languageClient else { return }
        var action = action
        // Resolved when its edit is to come: it carries data for that, or has nothing else to run.
        let needsEdit = action.edit == nil && (action.json["data"] != nil || action.command == nil)
        if needsEdit, client.resolvesCodeActions, (try? await client.resolve(action)).map({ action = $0 }) == nil {
            errorMessage = "“\(action.title)” couldn't be prepared by \(client.name)."
            return
        }
        if let edit = action.edit, !applyServerEdit(edit, actionName: action.title) { return }
        if let command = action.command {
            do { try await client.executeCommand(command) } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Applies a server's edit at once (each file one undo step). Returns whether it applied.
    @discardableResult
    func applyServerEdit(_ edit: WorkspaceEdit, actionName: String) -> Bool {
        do {
            let preview = try preview(edit, title: actionName, actionName: actionName)
            return apply(preview).isEmpty
        } catch {
            errorMessage = "“\(actionName)” couldn't be applied: \(error.localizedDescription)"
            return false
        }
    }

    /// ⌘.: the fixes and refactorings for the selection (or the cursor's line), in a menu at
    /// the cursor, with Fix with AI for the problems there.
    @discardableResult
    func showCodeActions(in target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let document = target ?? activeDocument, let editor = document.editor else { NSSound.beep(); return nil }
        let selection = editor.textView.selectedRange()
        return Task {
            let actions = await codeActions(for: document, range: selection)
            let aiFixes = editor.aiFixMenuItems(for: selection)
            guard !actions.isEmpty || !aiFixes.isEmpty else { NSSound.beep(); return }
            let caret = editor.rect(for: NSRange(location: selection.location, length: 0)) ?? .zero
            editor.showCodeActionMenu(actions, extra: aiFixes, at: NSPoint(x: caret.minX, y: caret.maxY), in: editor.textView) { action in
                Task { await self.run(action, in: document) }
            }
        }
    }

    /// Source → Organize Imports.
    @discardableResult
    func organizeImports(in target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let document = target ?? activeDocument else { NSSound.beep(); return nil }
        return Task {
            let whole = NSRange(location: 0, length: document.textStorage.length)
            guard let action = await codeActions(for: document, range: whole, only: ["source.organizeImports"])
                .first(where: { $0.kind.hasPrefix("source.organizeImports") }) else {
                NSSound.beep()
                return
            }
            await run(action, in: document)
        }
    }
}

extension EditorController {
    /// The actions as a menu (quick fixes, then refactorings, then source actions, then `extra`
    /// items under "AI"), the preferred one bold; disabled ones say why.
    func showCodeActionMenu(_ actions: [CodeAction], extra: [NSMenuItem] = [], at point: NSPoint, in view: NSView,
                            run: @escaping (CodeAction) -> Void) {
        let menu = Self.codeActionMenu(actions, extra: extra, run: run)
        menu.popUp(positioning: menu.items.first { $0.isEnabled && !$0.isSectionHeader }, at: point, in: view)
    }

    static func codeActionMenu(_ actions: [CodeAction], extra: [NSMenuItem] = [], run: @escaping (CodeAction) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Code Actions")
        menu.autoenablesItems = false
        let groups: [(String, (CodeAction) -> Bool)] = [
            ("Quick Fix", \.isQuickFix), ("Refactor", \.isRefactor), ("Source", \.isSource),
            ("More Actions", { !$0.isQuickFix && !$0.isRefactor && !$0.isSource }),
        ]
        for (title, belongs) in groups {
            let members = actions.filter(belongs)
            guard !members.isEmpty else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: title))
            for action in members {
                let item = ClosureMenuItem(action.title) { run(action) }
                if action.isPreferred {
                    item.attributedTitle = NSAttributedString(string: action.title, attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
                }
                if let reason = action.disabledReason {
                    item.isEnabled = false
                    item.toolTip = reason
                }
                menu.addItem(item)
            }
        }
        if !extra.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: "AI"))
            extra.forEach(menu.addItem)
        }
        return menu
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

/// The 💡 beside the cursor's line when the server has fixes for a problem there.
@MainActor
final class LightbulbController {
    /// Weak: it may close while a request is out.
    private weak var editor: EditorController?
    private var task: Task<Void, Never>?
    private var button: NSButton?
    /// The actions the bulb offers (tests).
    private(set) var actions: [CodeAction] = []
    private(set) var line: Int?
    /// The selection the actions are for (Fix with AI offers the problems it touches).
    private var selection = NSRange(location: 0, length: 0)
    nonisolated(unsafe) static var delay: Duration = .milliseconds(300)

    init(editor: EditorController) {
        self.editor = editor
    }

    var isShown: Bool { button?.isHidden == false }

    /// The cursor moved or the text changed: ask again (after a pause) if its line has problems.
    func update() {
        task?.cancel()
        guard let editor else { return }
        let document = editor.document
        let selection = editor.textView.selectedRange()
        let cursorLine = document.lineIndex.line(containing: selection.location)
        if line != cursorLine { hide() }
        let asksServer = document.languageClient.map { $0.state == .ready && $0.supports(.codeAction) } ?? false
        // With AI set up, any problem can be fixed with it (the Problems panel's too).
        let offersAI = editor.inlineEdit.settings.isConfigured
        let hasProblem = asksServer
            && document.diagnostics.contains(where: { $0.range.start.line <= cursorLine && $0.range.end.line >= cursorLine })
        guard hasProblem || (offersAI && !editor.problems(touching: selection).isEmpty),
              let workspace = document.workspace else {
            hide()
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self, let editor = self.editor else { return }
            let version = document.editVersion
            let actions = asksServer ? await workspace.codeActions(for: document, range: selection) : []
            guard !Task.isCancelled, document.editVersion == version else { return }
            self.actions = actions.filter { $0.disabledReason == nil }
            self.selection = selection
            if self.actions.isEmpty && !(offersAI && !editor.problems(touching: selection).isEmpty) {
                self.hide()
            } else {
                self.show(line: cursorLine)
            }
        }
    }

    func hide() {
        button?.isHidden = true
        line = nil
        actions = []
    }

    private func show(line: Int) {
        guard let editor, let gutter = editor.gutterView, let rect = editor.rect(for: NSRange(location: editor.document.lineIndex.lineStarts[line], length: 0)) else { return }
        let button = self.button ?? makeButton(in: gutter)
        let origin = gutter.convert(NSPoint(x: 0, y: rect.minY), from: editor.textView)
        let size: CGFloat = 14
        button.frame = NSRect(x: gutter.leadingWidth + GutterView.changeStripWidth - 1, y: origin.y + (rect.height - size) / 2,
                              width: size, height: size)
        button.isHidden = false
        self.line = line
    }

    private func makeButton(in gutter: GutterView) -> NSButton {
        let image = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Code actions")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.systemYellow])))
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(clicked))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = "Show Code Actions (⌘.)"
        gutter.addSubview(button)
        self.button = button
        return button
    }

    @objc private func clicked() {
        guard let editor, let button, let workspace = editor.document.workspace else { return }
        let document = editor.document
        editor.showCodeActionMenu(actions, extra: editor.aiFixMenuItems(for: selection),
                                  at: NSPoint(x: 0, y: button.bounds.maxY), in: button) { action in
            Task { await workspace.run(action, in: document) }
        }
    }

    /// Scrolling moves the line: the bulb goes until the cursor moves again.
    func viewportMoved() {
        if isShown, let line { show(line: line) }
    }
}
