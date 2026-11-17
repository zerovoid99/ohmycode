import AppKit
import SwiftUI

/// One ⌘I edit: the instruction, the reply as it streams, and where it goes.
@MainActor
@Observable
final class InlineEditModel {
    enum Phase: Equatable {
        case prompting, streaming, done
        case failed(String)
    }

    var instruction = ""
    var phase: Phase = .prompting
    /// The replacement so far (cleaned up as it streams).
    var output = ""
    /// The text it replaces (empty: code to insert at the caret).
    let original: String
    /// The file's name, for the header.
    let fileName: String
    let canOpenAsDiff: Bool

    init(original: String, fileName: String, canOpenAsDiff: Bool) {
        self.original = original
        self.fileName = fileName
        self.canOpenAsDiff = canOpenAsDiff
    }

    var isInsertion: Bool { original.isEmpty }
    var diff: [AIEditDiff.Row] { AIEditDiff.rows(old: original, new: output) }
    var canAccept: Bool { phase == .done && !output.isEmpty }
}

/// ⌘I for one editor: edits the selection (or writes code at the caret) from an instruction,
/// shown in a popover as a diff to accept or reject.
@MainActor
final class InlineEditController {
    private unowned let editor: EditorController
    var settings = AISettings.shared
    private(set) var model: InlineEditModel?
    /// What's being replaced: the range, and the text it had when the edit began.
    private(set) var range = NSRange(location: 0, length: 0)
    private var task: Task<Void, Never>?
    private var raw = ""
    private var popover: NSPopover?

    init(editor: EditorController) {
        self.editor = editor
    }

    private var document: EditorDocument { editor.document }

    /// The range an edit begins with: the selection; without one, the caret's line when it's
    /// blank (the code is written there, indented as the reply has it), else the caret's line
    /// as a whole (the instruction applies to it).
    static func editRange(selection: NSRange, text: NSString, lineIndex: LineIndex) -> NSRange {
        guard selection.length == 0 else { return selection }
        let line = lineIndex.line(containing: selection.location)
        let start = lineIndex.lineStarts[line]
        let end = line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[line + 1] - 1 : text.length
        var contentEnd = end
        if contentEnd > start, text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 } // CRLF
        return NSRange(location: start, length: contentEnd - start)
    }

    /// ⌘I: shows the instruction field at the selection.
    func begin() {
        guard let textView = editor.textView, textView.isEditable else { return }
        cancel()
        editor.inlineSuggestions.dismiss()
        editor.clearExtraCursors()
        let text = document.textStorage.mutableString
        range = Self.editRange(selection: textView.selectedRange(), text: text, lineIndex: document.lineIndex)
        let original = text.substring(with: range)
        // A blank line is written over, indentation included.
        let blank = original.trimmingCharacters(in: .whitespaces).isEmpty
        model = InlineEditModel(original: blank ? "" : original, fileName: document.fileName,
                                canOpenAsDiff: document.workspace != nil)
        showPopover()
    }

    /// Sends the instruction; the reply streams into the model.
    func submit() {
        guard let model, !model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task?.cancel()
        let provider: any AIProvider
        do {
            provider = try settings.makeProvider()
        } catch {
            model.phase = .failed(error.localizedDescription)
            return
        }
        let text = document.textStorage.mutableString
        guard NSMaxRange(range) <= text.length else {
            model.phase = .failed("The file changed: the selection isn't there anymore.")
            return
        }
        let request = AIPrompts.editRequest(text: text, range: model.isInsertion ? NSRange(location: range.location, length: 0) : range,
                                            instruction: model.instruction, path: document.relativePath,
                                            languageId: document.languageId, model: settings.editModel)
        raw = ""
        model.output = ""
        model.phase = .streaming
        let settings = self.settings
        task = Task { [weak self] in
            settings.requestStarted()
            defer { settings.requestEnded() }
            do {
                for try await piece in provider.stream(request) {
                    guard let self, self.model === model else { return }
                    self.raw += piece
                    model.output = AIPrompts.stripFences(self.raw)
                }
                guard let self, self.model === model else { return }
                model.output = AIPrompts.sanitizeEdit(self.raw, original: model.original)
                model.phase = .done
            } catch {
                guard let self, self.model === model, !Task.isCancelled else { return }
                model.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Waits for the reply (tests).
    func waitForReply() async { await task?.value }

    /// Stops the reply where it is (what came so far can still be accepted).
    func stop() {
        task?.cancel()
        task = nil
        guard let model, model.phase == .streaming else { return }
        model.output = AIPrompts.sanitizeEdit(raw, original: model.original)
        model.phase = .done
    }

    /// Whether the text being replaced is still as it was.
    var isRangeIntact: Bool {
        guard let model else { return false }
        let text = document.textStorage.mutableString
        guard NSMaxRange(range) <= text.length else { return false }
        let current = text.substring(with: range)
        return model.isInsertion ? current.trimmingCharacters(in: .whitespaces).isEmpty : current == model.original
    }

    /// ⌘↩: replaces exactly the original range with the reply, as one undoable edit. Refused
    /// (with a message, to regenerate) when that text changed meanwhile.
    @discardableResult
    func accept() -> Bool {
        guard let model, model.canAccept else { return false }
        guard isRangeIntact else {
            model.phase = .failed("The code changed since this was asked for. Try again to regenerate it.")
            return false
        }
        let textView = editor.textView!
        let replacement = model.output
        textView.breakUndoCoalescing()
        textView.insertText(replacement, replacementRange: range)
        textView.breakUndoCoalescing()
        textView.setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
        close()
        editor.focus()
        return true
    }

    /// Esc: closes without changing anything.
    func cancel() {
        task?.cancel()
        task = nil
        guard model != nil else { return }
        close()
    }

    /// Opens the reply as a proposed change in a diff tab, accepted or rejected there.
    func openAsDiff() {
        guard let model, model.canAccept, let workspace = document.workspace else { return }
        let text = document.textStorage.mutableString
        guard isRangeIntact else {
            model.phase = .failed("The code changed since this was asked for. Try again to regenerate it.")
            return
        }
        let proposed = text.replacingCharacters(in: range, with: model.output)
        let change = ProposedChange(title: "\(document.fileName) (AI Edit)", source: "AI", old: text as String, new: proposed)
        let range = self.range
        let replacement = model.output
        let original = text.substring(with: range)
        close()
        workspace.showProposedChange(change, for: document.url) { [weak self] accepted in
            guard accepted, let self else { return }
            let current = self.document.textStorage.mutableString
            guard NSMaxRange(range) <= current.length, current.substring(with: range) == original else {
                NSSound.beep()
                return
            }
            if let textView = self.editor.textView {
                textView.breakUndoCoalescing()
                textView.insertText(replacement, replacementRange: range)
                textView.breakUndoCoalescing()
            } else {
                _ = try? self.document.apply([TextReplacement(range: range, text: replacement)], actionName: "AI Edit")
            }
        }
    }

    private func close() {
        task?.cancel()
        task = nil
        model = nil
        let popover = self.popover
        self.popover = nil
        popover?.close()
    }

    private func showPopover() {
        guard let model, let textView = editor.textView, textView.window?.isVisible == true else { return }
        let anchor = editor.rect(for: NSRange(location: range.location, length: min(range.length, 1)))
            ?? NSRect(x: 0, y: textView.visibleRect.minY, width: 1, height: 16)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: InlineEditView(
            model: model,
            submit: { [weak self] in self?.submit() },
            stop: { [weak self] in self?.stop() },
            accept: { [weak self] in self?.accept() },
            reject: { [weak self] in self?.cancel(); self?.editor.focus() },
            openAsDiff: { [weak self] in self?.openAsDiff() }))
        self.popover = popover
        popover.show(relativeTo: NSRect(x: anchor.minX, y: anchor.minY, width: max(anchor.width, 1), height: anchor.height),
                     of: textView, preferredEdge: .maxY)
    }
}

/// The ⌘I popover: the instruction, then the reply as a diff against the selection.
struct InlineEditView: View {
    let model: InlineEditModel
    let submit: () -> Void
    let stop: () -> Void
    let accept: () -> Void
    let reject: () -> Void
    let openAsDiff: () -> Void
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField(model.isInsertion ? "Describe the code to write…" : "Describe the change…", text: $model.instruction)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onSubmit(submit)
                    .disabled(model.phase == .streaming)
                if model.phase == .streaming {
                    ProgressView().controlSize(.small)
                    Button(action: stop) { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop")
                }
            }
            if model.phase != .prompting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.diff) { row in
                            Text(prefix(row.kind) + (row.text.isEmpty ? " " : row.text))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(row.kind == .same ? Color.secondary : Color.primary)
                                .background(background(row.kind))
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.phase == .prompting {
                    Text("↩ to send, Esc to cancel").font(.caption).foregroundStyle(.secondary)
                } else if case .failed = model.phase {
                    Button("Try Again", action: submit)
                }
                Spacer()
                if model.canOpenAsDiff, model.phase == .done {
                    Button("Open as Diff", action: openAsDiff).disabled(!model.canAccept)
                }
                Button(model.phase == .prompting ? "Cancel" : "Reject", action: reject)
                    .keyboardShortcut(.cancelAction)
                if model.phase != .prompting {
                    Button("Accept", action: accept)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canAccept)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 460)
        .onAppear { isFieldFocused = true }
    }

    private func prefix(_ kind: AIEditDiff.Kind) -> String {
        switch kind {
        case .same: "  "
        case .removed: "- "
        case .added: "+ "
        }
    }

    private func background(_ kind: AIEditDiff.Kind) -> Color {
        switch kind {
        case .same: .clear
        case .removed: .red.opacity(0.18)
        case .added: .green.opacity(0.18)
        }
    }
}
