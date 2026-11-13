import AppKit
import SwiftUI

/// The blame text drawn after the cursor's line.
struct BlameAnnotation {
    let text: String
    /// Where the text is drawn, in the text view; also where the mouse hovers and clicks.
    let rect: NSRect
    let blame: BlameLine
    /// The mouse is on it (it's drawn underlined: clicking opens the commit's changes).
    var isHovered = false

    var origin: NSPoint { rect.origin }
}

/// Hovering the blame annotation shows its commit (whole message, author, email, date) with
/// actions; clicking it opens what the commit changed in the file.
@MainActor
final class BlameHoverController {
    nonisolated(unsafe) static var delay: Duration = .milliseconds(350)

    private unowned let editor: EditorController
    private var task: Task<Void, Never>?
    private var popover: NSPopover?
    private(set) var isMouseOnAnnotation = false
    /// The commit the popover shows (tests).
    private(set) var shownCommit: String?

    init(editor: EditorController) {
        self.editor = editor
    }

    var isShown: Bool { popover?.isShown == true || shownCommit != nil }

    /// Returns true while the mouse is on a committed line's annotation (other hovers wait).
    func mouseMoved(to point: NSPoint) -> Bool {
        // Closed by a click elsewhere (transient): forget it, so hovering shows it again.
        if let popover, !popover.isShown, editor.textView.window != nil { self.popover = nil; shownCommit = nil }
        let annotation = editor.blameAnnotation()
        let isOn = annotation.map { !$0.blame.isUncommitted && $0.rect.insetBy(dx: -2, dy: 0).contains(point) } ?? false
        if isOn != isMouseOnAnnotation {
            isMouseOnAnnotation = isOn
            editor.diagnosticsOverlay?.needsDisplay = true
        }
        guard isOn, let annotation else {
            if isShown || task != nil { dismiss() }
            return false
        }
        NSCursor.pointingHand.set()
        guard shownCommit != annotation.blame.commit, task == nil else { return true }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            await self.show(annotation)
            self.task = nil
        }
        return true
    }

    /// Leaving the text view: keep the popover only if the mouse went into it.
    func mouseExited() {
        task?.cancel()
        task = nil
        if isMouseOnAnnotation {
            isMouseOnAnnotation = false
            editor.diagnosticsOverlay?.needsDisplay = true
        }
        guard isShown else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            if let window = self.popover?.contentViewController?.view.window, window.frame.contains(NSEvent.mouseLocation) { return }
            self.dismiss()
        }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        popover?.close()
        popover = nil
        shownCommit = nil
    }

    /// Shows the commit of `annotation`'s line, once its details are read.
    func show(_ annotation: BlameAnnotation) async {
        guard let actions = editor.document.blameActions else { return }
        let blame = annotation.blame
        let details = await actions.details(blame)
        // The cursor may have moved to another line meanwhile.
        guard !Task.isCancelled, let details, editor.blameAnnotation()?.blame == blame else { return }
        popover?.close()
        let content = BlameCommitView(details: details, path: blame.path) { [weak self] action in
            self?.dismiss()
            switch action {
            case .openChanges: actions.openChanges(blame)
            case .showInTimeline: actions.showInTimeline(blame)
            case .copyHash:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(details.sha, forType: .string)
            }
        }
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        self.popover = popover
        shownCommit = blame.commit
        if editor.textView.window != nil {
            popover.show(relativeTo: annotation.rect, of: editor.textView, preferredEdge: .minY)
        }
    }
}

extension EditorController {
    /// Clicking the blame annotation opens what its commit changed in the file.
    func handleBlameClick(at point: NSPoint) -> Bool {
        guard let annotation = blameAnnotation(), !annotation.blame.isUncommitted,
              annotation.rect.insetBy(dx: -2, dy: 0).contains(point),
              let actions = document.blameActions else { return false }
        blameHover.dismiss()
        actions.openChanges(annotation.blame)
        return true
    }
}

/// The blame popover: the commit's message, author and date, and what to do with it.
struct BlameCommitView: View {
    enum Action { case openChanges, showInTimeline, copyHash }

    let details: CommitDetails
    let path: String?
    let perform: (Action) -> Void

    private var subject: String { details.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
    private var body_: String {
        let parts = details.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text(details.author).fontWeight(.semibold)
                if !details.email.isEmpty { Text("<\(details.email)>").foregroundStyle(.secondary) }
            }
            HStack(spacing: 4) {
                Text(details.date, format: .relative(presentation: .named))
                Text("·")
                Text(details.date.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            Text(subject).fontWeight(.medium).textSelection(.enabled)
            if !body_.isEmpty {
                ScrollView {
                    Text(body_)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Open Changes", systemImage: "doc.text.magnifyingglass") { perform(.openChanges) }
                    .help(path.map { "What \(details.shortSHA) changed in \($0)" } ?? "What this commit changed in the file")
                Button("Show in Timeline", systemImage: "clock.arrow.circlepath") { perform(.showInTimeline) }
                    .help("Find the commit in the repository log")
                Spacer(minLength: 8)
                Button { perform(.copyHash) } label: {
                    Label(details.shortSHA, systemImage: "doc.on.doc").monospaced()
                }
                .help("Copy the commit hash")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .font(.system(size: 12))
        .frame(width: 420, alignment: .leading)
        .padding(12)
    }
}
