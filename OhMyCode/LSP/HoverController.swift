import AppKit
import SwiftUI

/// Shows documentation and diagnostics for the symbol under the mouse after a short rest.
@MainActor
final class HoverController {
    nonisolated(unsafe) static var delay: Duration = .milliseconds(500)

    /// Weak: it may close while a delayed lookup is pending.
    private weak var editor: EditorController?
    private var task: Task<Void, Never>?
    private var popover: NSPopover?
    /// The hovered word, in text view coordinates; moving within it keeps the popover.
    private var anchorRect: NSRect?
    /// What the popover shows (tests).
    private(set) var shownMarkdown: String?
    private(set) var shownDiagnostics: [Diagnostic] = []

    init(editor: EditorController) {
        self.editor = editor
    }

    var isShown: Bool { popover?.isShown == true }

    func mouseMoved(to point: NSPoint) {
        if isShown, let anchorRect, anchorRect.insetBy(dx: -2, dy: -2).contains(point) { return }
        dismiss()
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self, let index = self.editor?.characterIndex(at: point) else { return }
            await self.show(at: index)
        }
    }

    /// Leaving the text view: keep the popover only if the mouse went into it.
    func mouseExited() {
        task?.cancel()
        guard isShown else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let window = self.popover?.contentViewController?.view.window,
                  !window.frame.contains(NSEvent.mouseLocation) else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        popover?.close()
        popover = nil
        anchorRect = nil
        shownMarkdown = nil
        shownDiagnostics = []
    }

    /// Looks up hover info for the text at `index` and shows it. Returns whether anything was shown.
    @discardableResult
    func show(at index: Int) async -> Bool {
        // Held for the lookup: the editor stays while its hover is worked out.
        guard let editor else { return false }
        let document = editor.document
        let version = document.editVersion
        let range = editor.wordRange(at: index) ?? NSRange(location: index, length: 0)

        let diagnostics = document.diagnostics.filter {
            let diagnosticRange = document.range(for: $0.range)
            return NSLocationInRange(index, diagnosticRange) || (diagnosticRange.length == 0 && diagnosticRange.location == index)
        }.sorted { $0.severity.rawValue < $1.severity.rawValue }

        var markdown: String?
        if range.length > 0 {
            // The server's hover, then the extensions'.
            var server: String?
            if let client = document.languageClient, client.state == .ready, client.supports(.hover) {
                server = try? await client.hover(url: document.url, position: document.lspPosition(at: index))
            }
            let fromExtensions = await document.extensionHost?.hovers(for: document, at: index) ?? []
            let parts = [server].compactMap { $0 }.filter { !$0.isEmpty } + fromExtensions
            markdown = parts.isEmpty ? nil : parts.joined(separator: "\n\n---\n\n")
        }
        guard !Task.isCancelled, document.editVersion == version, markdown != nil || !diagnostics.isEmpty,
              let rect = editor.rect(for: range.length > 0 ? range : NSRange(location: index, length: 1)) else { return false }

        popover?.close()
        let content = HoverView(diagnostics: diagnostics, blocks: markdown.map(HoverContent.blocks) ?? [])
        let controller = NSHostingController(rootView: content)
        controller.preferredContentSize = content.fittingSize
        controller.sizingOptions = []
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        self.popover = popover
        anchorRect = rect
        shownMarkdown = markdown
        shownDiagnostics = diagnostics
        if editor.textView.window != nil {
            popover.show(relativeTo: rect, of: editor.textView, preferredEdge: .minY)
        }
        return true
    }
}

struct HoverView: View {
    static let maxWidth: CGFloat = 520
    static let maxHeight: CGFloat = 340

    let diagnostics: [Diagnostic]
    let blocks: [HoverContent.Block]

    var body: some View {
        ScrollView { padded }
    }

    /// Natural size of the content (wrapped at the max width), capped at the max height.
    var fittingSize: NSSize {
        let measure = NSHostingController(rootView: padded)
        let size = measure.sizeThatFits(in: CGSize(width: Self.maxWidth, height: 10_000))
        return NSSize(width: min(Self.maxWidth, ceil(size.width)), height: min(Self.maxHeight, ceil(size.height)))
    }

    private var padded: some View {
        content
            .frame(maxWidth: Self.maxWidth - 20, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Self.icon(for: diagnostic.severity))
                        .foregroundStyle(Self.color(for: diagnostic.severity))
                    Text(diagnostic.message).textSelection(.enabled)
                    if let source = diagnostic.source {
                        Text(source).foregroundStyle(.secondary)
                    }
                }
            }
            if !diagnostics.isEmpty && !blocks.isEmpty { Divider() }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                case .text(let text):
                    Text(Self.attributed(text)).textSelection(.enabled)
                case .rule:
                    Divider()
                }
            }
        }
        .font(.system(size: 12))
    }

    private static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    static func icon(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        case .hint: "lightbulb"
        }
    }

    static func color(for severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .yellow
        case .information: .blue
        case .hint: .secondary
        }
    }
}
