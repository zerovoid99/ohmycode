import AppKit
import SwiftUI

/// Explain with AI and Fix with AI: where they're offered (editor, Problems, code actions,
/// terminal) and the explanation popover. Nothing is sent until one is chosen.
enum AIActions {
    /// The tooltip of AI actions while no provider is set up.
    static let notConfiguredHelp = "Set up AI in Settings ▸ AI"
    /// Longest problem message shown in a "Fix with AI" menu item.
    static let menuMessageLength = 60
}

// MARK: Explanations

/// One explanation: the Markdown reply as it streams.
@MainActor
@Observable
final class AIExplainModel: Identifiable {
    enum Phase: Equatable {
        case streaming, done, stopped
        case failed(String)
    }

    let id = UUID()
    let title: String
    /// What's explained ("main.swift:12-14", "Terminal").
    let subtitle: String
    private(set) var phase: Phase = .streaming
    /// The reply so far (Markdown).
    private(set) var text = ""
    /// Hands the code or output and a question to the Agent sidebar (nil: not offered).
    @ObservationIgnored var askAgent: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var request: AIRequest?
    @ObservationIgnored private var settings: AISettings?

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var blocks: [AgentMarkdown.Block] { AgentMarkdown.blocks(text) }
    var isStreaming: Bool { phase == .streaming }

    /// Sends `request`; the reply streams into `text`.
    func start(_ request: AIRequest, settings: AISettings) {
        self.request = request
        self.settings = settings
        task?.cancel()
        text = ""
        let provider: any AIProvider
        do {
            provider = try settings.makeProvider()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .streaming
        task = Task { [weak self] in
            settings.requestStarted()
            defer { settings.requestEnded() }
            do {
                for try await piece in provider.stream(request) {
                    guard let self, !Task.isCancelled else { return }
                    self.text += piece
                }
                guard let self, !Task.isCancelled else { return }
                self.phase = .done
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        guard let request, let settings else { return }
        start(request, settings: settings)
    }

    /// Stops the reply where it is.
    func stop() {
        task?.cancel()
        task = nil
        if phase == .streaming { phase = .stopped }
    }

    /// Waits for the reply (tests).
    func waitForReply() async { await task?.value }
}

/// The explanation popover: the reply as Markdown, with Stop, Copy and Ask Agent.
struct AIExplainView: View {
    let model: AIExplainModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text(model.title).font(.headline)
                Text(model.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if model.isStreaming { ProgressView().controlSize(.small) }
            }
            ScrollView {
                if model.text.isEmpty {
                    Text(model.isStreaming ? "Thinking…" : "No explanation.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    AgentMarkdownView(text: model.text)
                }
            }
            .font(.system(size: 12))
            .frame(minHeight: 60, maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isStreaming {
                    Button("Stop", action: model.stop)
                } else if case .failed = model.phase {
                    Button("Try Again", action: model.retry)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }
                .disabled(model.text.isEmpty)
                if let askAgent = model.askAgent {
                    Button("Ask Agent") {
                        askAgent()
                        close()
                    }
                    .help("Continue in the Agent sidebar, with this attached")
                }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 520)
    }
}

/// Shows one explanation at a time, in a popover; closing it stops the reply.
@MainActor
final class AIExplainPresenter: NSObject, NSPopoverDelegate {
    static let shared = AIExplainPresenter()

    /// The explanation showing (or, in a window that isn't on screen, the last one asked for).
    private(set) var model: AIExplainModel?
    private var popover: NSPopover?

    func present(_ model: AIExplainModel, relativeTo rect: NSRect, of view: NSView) {
        close()
        self.model = model
        guard view.window?.isVisible == true else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: AIExplainView(model: model) { [weak self] in self?.close() })
        self.popover = popover
        popover.show(relativeTo: NSRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: max(rect.height, 1)),
                     of: view, preferredEdge: .maxY)
    }

    func close() {
        let popover = self.popover
        self.popover = nil
        model?.stop()
        model = nil
        popover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        model?.stop()
        model = nil
    }
}

// MARK: Editor

extension EditorController {
    /// Problems on the lines `range` touches, the language server's and the Problems panel's
    /// (tasks', extensions'), most severe first.
    func problems(touching range: NSRange) -> [Diagnostic] {
        let lines = document.lineIndex
        let first = lines.line(containing: range.location), last = lines.line(containing: NSMaxRange(range))
        var all = document.diagnostics
        if let workspace = document.workspace {
            for diagnostic in workspace.problems.sources(for: document.url).values.flatMap({ $0 })
            where !all.contains(where: { $0.range == diagnostic.range && $0.message == diagnostic.message }) {
                all.append(diagnostic)
            }
        }
        return all.filter { $0.range.start.line <= last && $0.range.end.line >= first }
            .enumerated().sorted { ($0.element.severity.rawValue, $0.offset) < ($1.element.severity.rawValue, $1.offset) }
            .map(\.element)
    }

    /// Explain with AI: the selection, or the caret's line (focused on the word at the caret).
    func explainWithAI() {
        guard let textView else { return }
        let text = document.textStorage.mutableString
        let selection = textView.selectedRange()
        guard text.length > 0, NSMaxRange(selection) <= text.length else { NSSound.beep(); return }
        let range = InlineEditController.editRange(selection: selection, text: text, lineIndex: document.lineIndex)
        guard !text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        let focus = selection.length == 0 ? wordRange(at: selection.location).map { text.substring(with: $0) } : nil
        let settings = inlineEdit.settings
        let request = AIPrompts.explainCodeRequest(text: text, range: range, lineIndex: document.lineIndex, focus: focus,
                                                   path: document.relativePath, languageId: document.languageId,
                                                   model: settings.editModel)
        let lines = lineRange(of: range)
        let model = AIExplainModel(title: "Explain", subtitle: "\(document.fileName):\(lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)-\(lines.upperBound)")")
        if let workspace = document.workspace, workspace.rootURL != nil {
            let attachment = AgentAttachment(url: document.url, lines: lines, text: text.substring(with: range))
            model.askAgent = { [weak workspace] in workspace?.askAgent("Explain this code.", attachment: attachment) }
        }
        model.start(request, settings: settings)
        let anchor = rect(for: NSRange(location: range.location, length: min(range.length, 1)))
            ?? NSRect(x: 0, y: textView.visibleRect.minY, width: 1, height: 16)
        AIExplainPresenter.shared.present(model, relativeTo: anchor, of: textView)
    }

    /// 1-based lines of `range` (one ending at a line's start doesn't take that line).
    private func lineRange(of range: NSRange) -> ClosedRange<Int> {
        let text = document.textStorage.mutableString
        let index = document.lineIndex
        let first = index.line(containing: range.location) + 1
        var end = NSMaxRange(range)
        if end > range.location, end <= text.length, text.character(at: end - 1) == 0x0A { end -= 1 }
        return first...max(first, index.line(containing: end) + 1)
    }

    /// Fix with AI for `diagnostic`, shown as a diff to accept (see `InlineEditController.beginFix`).
    func fixWithAI(_ diagnostic: Diagnostic) {
        hover.dismiss()
        inlineEdit.beginFix(diagnostic)
    }

    /// "Explain with AI" and, on a line with a problem, "Fix with AI", for the context menu:
    /// disabled, saying why, until AI is set up.
    func aiMenuItems() -> [NSMenuItem] {
        let configured = inlineEdit.settings.isConfigured
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: configured ? action : nil, keyEquivalent: "")
            item.target = self
            if !configured { item.toolTip = AIActions.notConfiguredHelp }
            return item
        }
        var items = [item("Explain with AI", #selector(contextExplainWithAI))]
        if let textView, !problems(touching: textView.selectedRange()).isEmpty {
            items.append(item("Fix with AI", #selector(contextFixWithAI)))
        }
        return items + [.separator()]
    }

    /// "Fix with AI: …" for each problem (at most three) on the lines `range` touches, for the
    /// code action menu.
    func aiFixMenuItems(for range: NSRange) -> [NSMenuItem] {
        let configured = inlineEdit.settings.isConfigured
        return problems(touching: range).prefix(3).map { diagnostic in
            var message = diagnostic.message.split(separator: "\n").first.map(String.init) ?? diagnostic.message
            if message.count > AIActions.menuMessageLength { message = String(message.prefix(AIActions.menuMessageLength - 1)) + "…" }
            let item = ClosureMenuItem("Fix with AI: \(message)") { [weak self] in self?.fixWithAI(diagnostic) }
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            if !configured {
                item.isEnabled = false
                item.toolTip = AIActions.notConfiguredHelp
            }
            return item
        }
    }

    @objc func contextExplainWithAI(_ sender: Any?) { explainWithAI() }

    @objc func contextFixWithAI(_ sender: Any?) {
        guard let textView, let diagnostic = problems(touching: textView.selectedRange()).first else { NSSound.beep(); return }
        fixWithAI(diagnostic)
    }
}

// MARK: Workspace

extension Workspace {
    /// Fix with AI from the Problems panel: opens the problem, then asks for the fix.
    func fixWithAI(_ diagnostic: Diagnostic, in url: URL) {
        open(problem: diagnostic, in: url)
        guard let document = activeDocument, FileWatcher.canonicalPath(document.url) == FileWatcher.canonicalPath(url) else { return }
        if let editor = document.editor, editor.textView?.window != nil {
            editor.fixWithAI(diagnostic)
            return
        }
        // A tab just opened: its editor comes with the next layout.
        Task { [weak document] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(25))
                if let editor = document?.editor, editor.textView?.window != nil {
                    editor.fixWithAI(diagnostic)
                    return
                }
            }
        }
    }

    /// The explanation of output from a terminal or a task (sent at once), with the active file
    /// and the command as context.
    func outputExplanation(_ output: String, source: String, command: String?,
                           settings: AISettings = .shared) -> AIExplainModel {
        let document = activeDocument
        let request = AIPrompts.explainOutputRequest(
            output: output, source: source, command: command,
            activeFile: document.map { relativePath(of: $0.url) ?? $0.fileName }, languageId: document?.languageId,
            model: settings.editModel)
        let model = AIExplainModel(title: "Explain Output", subtitle: source)
        if rootURL != nil {
            let excerpt = output.count > 4_000 ? String(output.suffix(4_000)) : output
            model.askAgent = { [weak self] in
                self?.askAgent("Explain this output and how to fix it\(command.map { " (from `\($0)`)" } ?? ""):\n\n```\n\(excerpt)\n```",
                               attachment: nil)
            }
        }
        model.start(request, settings: settings)
        return model
    }

    /// Explain with AI on a terminal's selection: the explanation in a popover at `rect`.
    func explainTerminalOutput(_ output: String, title: String?, from view: NSView, at rect: NSRect) {
        let model = outputExplanation(output, source: "Terminal", command: title)
        AIExplainPresenter.shared.present(model, relativeTo: rect, of: view)
    }

    /// Ask Agent: shows the Agent sidebar with `question` in the prompt and `attachment`
    /// attached. Nothing is sent until the prompt is.
    func askAgent(_ question: String, attachment: AgentAttachment?) {
        sidebarMode = .agent
        if let attachment { agentPanel.attachments.append(attachment) }
        let draft = agentPanel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        agentPanel.draft = draft.isEmpty ? question : draft + "\n\n" + question
    }
}
