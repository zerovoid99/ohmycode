import AppKit
import Observation

/// Edits to several files, shown for review before they're applied (rename, replace all).
/// Edits are computed against each file's text at preview time; a file that changed since is
/// skipped when applying rather than edited at the wrong places.
@MainActor
@Observable
final class EditPreview: Identifiable {
    struct FileEdit: Identifiable {
        var id: URL { url }
        let url: URL
        let path: String
        let edits: [TextReplacement]
        /// The text `edits` were computed against.
        let baseText: String
        var isIncluded = true
        /// Before/after of each changed region, for display.
        let changes: [LineChange]

        init(url: URL, path: String, edits: [TextReplacement], baseText: String) {
            self.url = url
            self.path = path
            self.edits = edits
            self.baseText = baseText
            changes = LineChange.changes(edits, in: baseText)
        }
    }

    /// One changed region (one line, or a few lines when an edit spans them).
    struct LineChange: Identifiable {
        let id: Int
        /// Zero-based first line.
        let line: Int
        let old: String
        let new: String

        /// Groups edits into regions of whole lines and renders each before and after.
        static func changes(_ edits: [TextReplacement], in text: String) -> [LineChange] {
            let string = text as NSString
            guard let sorted = try? TextReplacement.validated(edits, length: string.length) else { return [] }
            let index = LineIndex(string: string)
            func lineEnd(_ line: Int) -> Int {
                line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : string.length
            }
            var result: [LineChange] = []
            var i = 0
            while i < sorted.count {
                let firstLine = index.line(containing: sorted[i].range.location)
                var lastLine = index.line(containing: NSMaxRange(sorted[i].range))
                var j = i + 1
                while j < sorted.count, index.line(containing: sorted[j].range.location) <= lastLine {
                    lastLine = max(lastLine, index.line(containing: NSMaxRange(sorted[j].range)))
                    j += 1
                }
                let start = index.lineStarts[firstLine]
                let region = NSRange(location: start, length: lineEnd(lastLine) - start)
                let local = sorted[i..<j].map {
                    TextReplacement(range: NSRange(location: $0.range.location - start, length: $0.range.length), text: $0.text)
                }
                let old = string.substring(with: region)
                let new = (try? TextReplacement.apply(local, to: old)) ?? old
                result.append(LineChange(id: result.count, line: firstLine, old: old, new: new))
                i = j
            }
            return result
        }
    }

    let title: String
    let actionName: String
    var files: [FileEdit]
    /// Called after the edits were applied (e.g. to search again).
    @ObservationIgnored var onApplied: (() -> Void)?

    init(title: String, actionName: String, files: [FileEdit]) {
        self.title = title
        self.actionName = actionName
        self.files = files.filter { !$0.edits.isEmpty }
    }

    var includedFiles: [FileEdit] { files.filter(\.isIncluded) }
    var changeCount: Int { includedFiles.reduce(0) { $0 + $1.edits.count } }
}

extension Workspace {
    /// Text and path for computing edits: the open document's text, or the file on disk.
    func currentText(of url: URL) -> String? {
        if let document = document(matching: url) { return document.textStorage.mutableString as String }
        guard let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Shows a preview for review (a sheet); `applyPendingEdit` applies it.
    func review(_ preview: EditPreview) {
        guard !preview.files.isEmpty else { NSSound.beep(); return }
        pendingEdit = preview
    }

    func cancelPendingEdit() {
        pendingEdit = nil
    }

    /// Applies the reviewed edits. Returns the paths of files that were skipped.
    @discardableResult
    func applyPendingEdit() -> [String] {
        guard let preview = pendingEdit else { return [] }
        pendingEdit = nil
        return apply(preview)
    }

    /// Applies edits through documents, so each file's change is one undo step. Files that
    /// aren't open are opened as tabs in the background (left unsaved, to review, save or
    /// undo), instead of being rewritten on disk.
    @discardableResult
    func apply(_ preview: EditPreview) -> [String] {
        var skipped: [String] = []
        for file in preview.includedFiles {
            // Changed since the preview (checked before opening, so skipped files don't get tabs).
            guard currentText(of: file.url) == file.baseText,
                  let document = document(matching: file.url) ?? openInBackground(file.url),
                  document.textStorage.mutableString.isEqual(to: file.baseText) else {
                skipped.append(file.path)
                continue
            }
            do {
                try document.apply(file.edits, actionName: preview.actionName)
            } catch {
                skipped.append(file.path)
            }
        }
        if !skipped.isEmpty {
            errorMessage = "Some files changed since the preview and were left as they are: \(skipped.joined(separator: ", "))"
        }
        preview.onApplied?()
        return skipped
    }

    /// Opens a document as a tab in the active group without switching to it.
    func openInBackground(_ url: URL) -> EditorDocument? {
        if let existing = document(matching: url) { return existing }
        let active = activeDocumentID
        open(fileAt: url)
        guard let document = document(matching: url) else { return nil }
        activeDocumentID = active ?? document.id
        return document
    }
}
