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

/// Hovering the blame annotation (or a line in the blame column) shows its commit (whole
/// message, author, email, date) with actions; clicking opens what the commit changed in the file.
@MainActor
final class BlameHoverController: NSObject, NSPopoverDelegate {
    nonisolated(unsafe) static var delay: Duration = .milliseconds(350)

    private unowned let editor: EditorController
    private var task: Task<Void, Never>?
    /// The commit waiting for the delay to show.
    private var pendingCommit: String?
    private var popover: NSPopover?
    private(set) var isMouseOnAnnotation = false
    /// The commit the popover shows (tests).
    private(set) var shownCommit: String?

    init(editor: EditorController) {
        self.editor = editor
    }

    /// Closed by a click elsewhere (transient): forget it, so hovering shows it again.
    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        popover = nil
        shownCommit = nil
    }

    var isShown: Bool { popover?.isShown == true || shownCommit != nil }

    /// The text view: returns true while the mouse is on a committed line's annotation (other
    /// hovers wait).
    func mouseMoved(to point: NSPoint) -> Bool {
        let annotation = editor.blameAnnotation()
        let isOn = annotation.map { !$0.blame.isUncommitted && $0.rect.insetBy(dx: -2, dy: 0).contains(point) } ?? false
        if isOn != isMouseOnAnnotation {
            isMouseOnAnnotation = isOn
            editor.diagnosticsOverlay?.needsDisplay = true
        }
        guard isOn, let annotation else {
            if isShown || pendingCommit != nil { dismiss() }
            return false
        }
        NSCursor.pointingHand.set()
        let blame = annotation.blame
        hover(blame, rect: annotation.rect, in: editor.textView) { [weak editor] in editor?.blameAnnotation()?.blame == blame }
        return true
    }

    /// The blame column: the hovered line (nil: none) and its rect in the gutter.
    func gutterMouseMoved(line: Int?, rect: NSRect) {
        guard let line, let blame = (editor.document.blame?[safe: line] ?? nil), !blame.isUncommitted else {
            if isShown || pendingCommit != nil { dismiss() }
            return
        }
        hover(blame, rect: rect, in: editor.gutterView) { [weak editor] in editor?.document.showsBlameColumn == true }
    }

    /// Shows `blame`'s commit after the delay, unless it's shown or about to be.
    private func hover(_ blame: BlameLine, rect: NSRect, in view: NSView, stillWanted: @escaping @MainActor () -> Bool) {
        guard shownCommit != blame.commit, pendingCommit != blame.commit else { return }
        dismiss()
        pendingCommit = blame.commit
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            await self.show(blame, rect: rect, in: view, stillWanted: stillWanted)
            if self.pendingCommit == blame.commit { self.pendingCommit = nil; self.task = nil }
        }
    }

    /// Leaving the text view or the gutter: keep the popover only if the mouse went into it.
    func mouseExited() {
        task?.cancel()
        task = nil
        pendingCommit = nil
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
        pendingCommit = nil
        let popover = self.popover
        self.popover = nil
        shownCommit = nil
        popover?.close()
    }

    /// Shows `blame`'s commit once its details are read, if still wanted then.
    private func show(_ blame: BlameLine, rect: NSRect, in view: NSView, stillWanted: @MainActor () -> Bool) async {
        guard let actions = editor.document.blameActions else { return }
        let details = await actions.details(blame)
        guard !Task.isCancelled, let details, stillWanted() else { return }
        popover?.close()
        let content = BlameCommitView(details: details, path: blame.path) { [weak self] action in
            self?.dismiss()
            switch action {
            case .openChanges: actions.openChanges(blame)
            case .showInTimeline: actions.showInTimeline(blame)
            case .copyHash: Self.copy(details.sha)
            }
        }
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        shownCommit = blame.commit
        if view.window != nil {
            popover.show(relativeTo: rect, of: view, preferredEdge: view === editor.gutterView ? .maxX : .minY)
        }
    }

    static func copy(_ sha: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sha, forType: .string)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
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

    /// A click in the blame column: the line's commit changes (nothing for uncommitted lines).
    func handleBlameColumnClick(line: Int) {
        guard let blame = (document.blame?[safe: line] ?? nil), !blame.isUncommitted, let actions = document.blameActions else { return }
        blameHover.dismiss()
        actions.openChanges(blame)
    }

    /// Shows or hides the blame column; beeps for files git doesn't know.
    func toggleBlameColumn() {
        guard document.canBlame || document.showsBlameColumn else { NSSound.beep(); return }
        blameHover.dismiss()
        document.showsBlameColumn.toggle()
    }

    /// The gutter's context menu: the blame column, and the line's commit.
    func gutterMenu(line: Int?) -> NSMenu? {
        guard document.canBlame else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(document.showsBlameColumn ? "Hide Blame" : "Show Blame") { [weak self] in
            self?.toggleBlameColumn()
        })
        if let line, let blame = (document.blame?[safe: line] ?? nil), !blame.isUncommitted, let actions = document.blameActions {
            menu.addItem(.separator())
            let short = String(blame.commit.prefix(7))
            menu.addItem(ClosureMenuItem("Open Changes of \(short)") { actions.openChanges(blame) })
            menu.addItem(ClosureMenuItem("Show \(short) in Timeline") { actions.showInTimeline(blame) })
            menu.addItem(ClosureMenuItem("Copy Commit Hash") { BlameHoverController.copy(blame.commit) })
        }
        return menu
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
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
