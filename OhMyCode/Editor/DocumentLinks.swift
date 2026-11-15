import AppKit

/// A link in the text: a URL written in it, or one the language server found (an import's
/// path). ⌘-hovering underlines it; ⌘-click follows it.
struct EditorLink: Equatable {
    var range: NSRange
    /// Nil until resolved (a server link without a target yet).
    var target: URL?
    var tooltip: String?
    /// The server link it is, to resolve (nil: a URL in the text).
    var serverIndex: Int?
}

extension EditorDocument {
    /// URLs written in the text: a scheme, then anything up to a space or quote.
    private static let urlPattern = try! NSRegularExpression(pattern: #"\b(?:https?|ftp|file)://[^\s<>"'`{}|\\^\[\]]+"#)

    /// Asks the language server for the file's links again (after `delay`, restarted by every call).
    func refreshLinks(after delay: Duration = .zero) {
        linksTask?.cancel()
        linksTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self, let client = self.languageClient, client.state == .ready, client.supports(.documentLink) else { return }
            let version = self.editVersion
            let links = (try? await client.documentLinks(url: self.url)) ?? []
            guard !Task.isCancelled, version == self.editVersion else { return }
            self.serverLinks = links
            self.serverLinksVersion = version
        }
    }

    /// Waits for the refresh in progress (tests).
    func waitForLinks() async { await linksTask?.value }

    /// The link at a character, if any: the server's, then a URL written on its line.
    func link(at index: Int) -> EditorLink? {
        guard index >= 0, index < textStorage.length else { return nil }
        // The server's links are for the text they were found in.
        if serverLinksVersion == editVersion {
            for (offset, link) in serverLinks.enumerated() {
                let range = range(for: link.range)
                if NSLocationInRange(index, range) {
                    return EditorLink(range: range, target: link.target, tooltip: link.tooltip, serverIndex: offset)
                }
            }
        }
        let line = lineIndex.line(containing: index)
        let start = lineIndex.lineStarts[line]
        let end = line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[line + 1] : textStorage.length
        return urls(in: NSRange(location: start, length: end - start)).first { NSLocationInRange(index, $0.range) }
    }

    /// URLs written in `range`.
    func urls(in range: NSRange) -> [EditorLink] {
        let text = textStorage.mutableString
        return Self.urlPattern.matches(in: text as String, range: range).compactMap { match in
            var found = match.range
            // Punctuation after a URL ends the sentence, and a ")" closes a parenthesis around it.
            while found.length > 0 {
                let last = text.character(at: NSMaxRange(found) - 1)
                let substring = text.substring(with: found)
                if ".,;:!?*'".utf16.contains(last)
                    || (last == 0x29 && substring.filter { $0 == ")" }.count > substring.filter { $0 == "(" }.count) {
                    found.length -= 1
                } else {
                    break
                }
            }
            guard let url = URL(string: text.substring(with: found)), url.host() != nil || url.isFileURL else { return nil }
            return EditorLink(range: found, target: url)
        }
    }

    /// The link's target, asking the server for it if it didn't say.
    func target(of link: EditorLink) async -> URL? {
        if let target = link.target { return target }
        guard let index = link.serverIndex, index < serverLinks.count, let client = languageClient,
              client.resolvesDocumentLinks else { return nil }
        return try? await client.resolveDocumentLink(serverLinks[index])?.target
    }
}

extension EditorController {
    /// Opens web (and other non-file) links; replaced in tests.
    nonisolated(unsafe) static var openExternal: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// The mouse moved, or ⌘ was pressed or let go: underline the link under the mouse while ⌘
    /// is held.
    func updateLinkHover(at point: NSPoint?, modifiers: NSEvent.ModifierFlags) {
        var link: EditorLink?
        if let point, modifiers.intersection([.command, .option, .shift, .control]) == .command,
           let index = characterIndex(at: point) {
            link = document.link(at: index)
        }
        if link != nil { NSCursor.pointingHand.set() } else if hoveredLink != nil { NSCursor.iBeam.set() }
        guard link?.range != hoveredLink?.range else { return }
        hoveredLink = link
        textView.toolTip = link.map { link in
            (link.tooltip ?? link.target?.absoluteString ?? "Follow link") + " (⌘-click)"
        }
        diagnosticsOverlay?.needsDisplay = true
    }

    /// The hovered link's underline.
    func linkUnderlineRect() -> NSRect? {
        guard let link = hoveredLink, NSMaxRange(link.range) <= document.textStorage.length else { return nil }
        return rect(for: link.range)
    }

    /// ⌘-click: follows the link there, if any (otherwise it's Go to Definition).
    func followLink(at point: NSPoint) -> Bool {
        guard let index = characterIndex(at: point), let link = document.link(at: index) else { return false }
        open(link)
        return true
    }

    func open(_ link: EditorLink) {
        // Known already: at once (no task hop).
        if let target = link.target { openLinkTarget(target); return }
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.document.target(of: link) else { NSSound.beep(); return }
            self.openLinkTarget(url)
        }
    }

    /// Files open in the editor (`#L12` or `#12` goes to that line); anything else in its app.
    func openLinkTarget(_ url: URL) {
        guard url.isFileURL, let workspace = document.workspace else { Self.openExternal(url); return }
        var file = url
        var line: Int?
        if let fragment = url.fragment(percentEncoded: false) {
            line = Int(fragment.drop { $0 == "L" || $0 == "l" }.prefix { $0.isNumber })
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            file = components?.url ?? url
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            workspace.errorMessage = "\(file.path) doesn't exist."
            return
        }
        if isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return
        }
        workspace.open(fileAt: file)
        if let line { workspace.activeDocument?.revealLine(line) }
    }

    /// Right-clicking a link: open it, or copy where it goes.
    func linkMenuItems(at index: Int) -> [NSMenuItem] {
        guard let link = document.link(at: index) else { return [] }
        let open = ClosureMenuItem("Open Link") { [weak self] in self?.open(link) }
        let copy = ClosureMenuItem("Copy Link Address") { [weak self] in
            Task { [weak self] in
                guard let url = await self?.document.target(of: link) else { NSSound.beep(); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.isFileURL && url.fragment == nil ? url.path : url.absoluteString, forType: .string)
            }
        }
        return [open, copy, .separator()]
    }
}
