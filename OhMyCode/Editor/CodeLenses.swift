import AppKit

extension EditorDocument {
    /// Asks the language server for the file's lenses again (after `delay`, restarted by every
    /// call), resolving the ones that come without a command.
    func refreshCodeLenses(after delay: Duration = .zero) {
        codeLensesTask?.cancel()
        codeLensesTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            guard AppSettings.shared.showsCodeLens, let client = self.languageClient, client.state == .ready,
                  client.supports(.codeLens) else {
                self.setCodeLenses([:])
                return
            }
            let version = self.editVersion
            guard var lenses = try? await client.codeLenses(url: self.url) else { return }
            if client.resolvesCodeLenses {
                for index in lenses.indices.prefix(300) where lenses[index].command == nil {
                    guard !Task.isCancelled else { return }
                    if let resolved = try? await client.resolveCodeLens(lenses[index]) { lenses[index] = resolved }
                }
            }
            guard !Task.isCancelled, version == self.editVersion else { return }
            var byLine: [Int: [CodeLens]] = [:]
            for lens in lenses where lens.title != nil { byLine[lens.range.start.line, default: []].append(lens) }
            self.setCodeLenses(byLine)
        }
    }

    func waitForCodeLenses() async { await codeLensesTask?.value }

    func setCodeLenses(_ lenses: [Int: [CodeLens]]) {
        let titles = { (lenses: [Int: [CodeLens]]) in lenses.mapValues { $0.compactMap(\.title) } }
        guard titles(lenses) != titles(codeLenses) else { codeLenses = lenses; return }
        codeLenses = lenses
        editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true }
    }

    /// Lines `old` became `count` lines: lenses below move with their lines; lenses on lines
    /// that were replaced stay until the next answer.
    func shiftCodeLenses(replacing old: Range<Int>, with count: Int) {
        guard !codeLenses.isEmpty else { return }
        let delta = count - old.count
        var shifted: [Int: [CodeLens]] = [:]
        for (line, lenses) in codeLenses {
            if line < old.lowerBound { shifted[line] = lenses } else if line >= old.upperBound { shifted[line + delta] = lenses }
        }
        codeLenses = shifted
    }
}

/// A lens drawn after its line: its text and where it is.
struct CodeLensMark {
    let rect: NSRect
    let title: String
    let lens: CodeLens
    let line: Int
}

extension EditorController {
    static var codeLensFont: NSFont {
        NSFont.systemFont(ofSize: max(9, EditorTheme.font.pointSize - 2))
    }

    /// The lenses on lines in view, after each line's end (and after the blame there).
    func codeLensMarks() -> [CodeLensMark] {
        guard AppSettings.shared.showsCodeLens, !document.codeLenses.isEmpty, let visible = visibleCharacterRange() else { return [] }
        let index = document.lineIndex
        let length = document.textStorage.length
        let first = index.line(containing: visible.location), last = index.line(containing: min(NSMaxRange(visible), length))
        let blame = blameAnnotation()
        let blameLine = blame.map { _ in index.line(containing: textView.selectedRange().location) }
        var marks: [CodeLensMark] = []
        for line in first...max(first, last) {
            guard let lenses = document.codeLenses[line], line < index.lineCount else { continue }
            let start = index.lineStarts[line]
            let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : length
            guard !document.isHidden(start) else { continue }
            let anchor: NSRect?
            if end > start {
                anchor = rect(for: NSRange(location: end - 1, length: 1)).map { NSRect(x: $0.maxX, y: $0.minY, width: 0, height: $0.height) }
            } else {
                anchor = rect(for: NSRange(location: start, length: min(1, length - start)))
            }
            guard let anchor else { continue }
            var x = (line == blameLine ? blame.map { $0.rect.maxX } : nil).map { $0 + 16 } ?? anchor.maxX + 28
            for lens in lenses {
                guard let title = lens.title else { continue }
                let size = (title as NSString).size(withAttributes: [.font: Self.codeLensFont])
                marks.append(CodeLensMark(rect: NSRect(x: x, y: anchor.minY, width: ceil(size.width), height: anchor.height),
                                          title: title, lens: lens, line: line))
                x += ceil(size.width) + 14
            }
        }
        return marks
    }

    /// The lens under a point (text view coordinates).
    func codeLens(at point: NSPoint) -> CodeLensMark? {
        codeLensMarks().first { $0.rect.insetBy(dx: -2, dy: 0).contains(point) }
    }

    /// Clicking a lens runs it.
    func handleCodeLensClick(at point: NSPoint) -> Bool {
        guard let mark = codeLens(at: point) else { return false }
        document.workspace?.run(mark.lens, in: document)
        return true
    }
}

extension Workspace {
    /// Runs a lens's command: references are shown here (VS Code's own command, which
    /// servers use for "N references"); anything else goes to the server.
    func run(_ lens: CodeLens, in document: EditorDocument) {
        let arguments = lens.command?["arguments"] as? [Any] ?? []
        if lens.commandName == "editor.action.showReferences" || arguments.count >= 3 && arguments[2] is [Any] && lens.commandName.contains("eference") {
            let locations = (arguments.count >= 3 ? arguments[2] as? [Any] : nil)?.compactMap(LSPLocation.init(json:)) ?? []
            guard !locations.isEmpty else { NSSound.beep(); return }
            let line = lens.range.start.line
            let symbol = document.lineIndex.lineCount > line
                ? document.wordRange(at: document.offset(for: lens.range.start)).map { document.textStorage.mutableString.substring(with: $0) } ?? ""
                : ""
            references = ReferenceList(symbol: symbol, results: referenceResults(locations))
            sidebarMode = .references
            return
        }
        guard let command = lens.command, !lens.commandName.isEmpty, let client = document.languageClient else { NSSound.beep(); return }
        Task {
            do { try await client.executeCommand(command) } catch {
                errorMessage = "“\(lens.title ?? lens.commandName)” couldn't run: \(error.localizedDescription)"
            }
        }
    }
}
