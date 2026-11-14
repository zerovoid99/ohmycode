import AppKit
import SwiftUI

/// Parameter hints: the signature of the call being typed, above the cursor, with the current
/// argument in bold. Opens on the server's trigger characters ("(", ","), follows typing and
/// cursor moves while open, and closes when the server has none (the call is closed) or on Esc.
@MainActor
final class SignatureHelpController {
    /// Weak: it may close while a request is out.
    private weak var editor: EditorController?
    private var task: Task<Void, Never>?
    private var popover: NSPopover?
    private var model = SignatureHelpModel()
    /// What's shown (tests).
    private(set) var help: SignatureHelp?
    nonisolated(unsafe) static var updateDelay: Duration = .milliseconds(60)

    init(editor: EditorController) {
        self.editor = editor
    }

    var isShown: Bool { help != nil }

    private var client: LanguageClient? {
        guard let client = editor?.document.languageClient, client.state == .ready, client.supports(.signatureHelp) else { return nil }
        return client
    }

    /// After each edit, with what was typed (nil for deletions and other edits).
    func textDidChange(typed: String?) {
        guard let client else { return }
        let triggers = client.signatureHelpTriggers
        // Typed text may be more than the key ("(" comes with its ")").
        let characters = typed.map { $0.map(String.init) } ?? []
        if let opening = characters.first(where: triggers.open.contains) {
            request(trigger: opening, isRetrigger: isShown, delay: .zero)
        } else if isShown {
            request(trigger: characters.first(where: triggers.update.contains), isRetrigger: true, delay: Self.updateDelay)
        }
    }

    /// The cursor moved (clicks, arrows): an open hint follows it.
    func selectionChanged() {
        guard isShown else { return }
        request(trigger: nil, isRetrigger: true, delay: Self.updateDelay)
    }

    /// ⇧⌘Space.
    func trigger() {
        guard client != nil else { NSSound.beep(); return }
        request(trigger: nil, isRetrigger: isShown, delay: .zero)
    }

    /// Waits for the request in flight (tests).
    func waitUntilIdle() async { await task?.value }

    private func request(trigger: String?, isRetrigger: Bool, delay: Duration) {
        guard let client, let document = editor?.document else { return }
        task?.cancel()
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let cursor = self?.editor?.textView.selectedRange().location else { return }
            let version = document.editVersion
            let help = try? await client.signatureHelp(url: document.url, position: document.lspPosition(at: cursor),
                                                       trigger: trigger, isRetrigger: isRetrigger)
            guard !Task.isCancelled, document.editVersion == version, let self else { return }
            if let help { self.show(help, at: cursor) } else { self.dismiss() }
        }
    }

    /// Esc closes it (when completion isn't open, which closes first).
    func handle(_ selector: Selector) -> Bool {
        guard isShown, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        dismiss()
        return true
    }

    func dismiss() {
        task?.cancel()
        popover?.close()
        popover = nil
        help = nil
    }

    private func show(_ help: SignatureHelp, at cursor: Int) {
        // Moving between overloads by hand sticks while the same list is shown.
        var help = help
        if let shown = self.help, shown.signatures == help.signatures { help.activeSignature = model.help?.activeSignature ?? help.activeSignature }
        self.help = help
        model.help = help
        guard let editor, editor.textView.window != nil,
              let rect = editor.rect(for: NSRange(location: cursor, length: 0)).map({ NSRect(x: $0.minX, y: $0.minY, width: 1, height: max($0.height, 1)) })
        else { return }
        if let popover, popover.isShown {
            popover.positioningRect = rect
            resize()
            return
        }
        let controller = NSHostingController(rootView: SignatureHelpView(model: model) { [weak self] in self?.resize() })
        controller.sizingOptions = []
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        self.popover = popover
        resize()
        popover.show(relativeTo: rect, of: editor.textView, preferredEdge: .minY)
    }

    private func resize() {
        guard let popover, let help = model.help else { return }
        popover.contentSize = SignatureHelpView.fittingSize(help)
    }
}

@MainActor
@Observable
final class SignatureHelpModel {
    var help: SignatureHelp?
}

struct SignatureHelpView: View {
    static let maxWidth: CGFloat = 560

    let model: SignatureHelpModel
    let resized: () -> Void

    var body: some View {
        if let help = model.help { Self.content(help, model: model, resized: resized).padding(8) }
    }

    static func fittingSize(_ help: SignatureHelp) -> NSSize {
        let measure = NSHostingController(rootView: content(help, model: nil, resized: {}).padding(8))
        let size = measure.sizeThatFits(in: CGSize(width: maxWidth, height: 400))
        return NSSize(width: min(maxWidth, ceil(size.width)), height: min(240, ceil(size.height)))
    }

    /// The signature with the current parameter bold, then its documentation.
    static func label(_ help: SignatureHelp) -> AttributedString {
        let signature = help.signatures[help.activeSignature]
        var text = AttributedString(signature.label)
        if let range = help.highlighted, let bounds = Range(range, in: signature.label),
           let lower = AttributedString.Index(bounds.lowerBound, within: text),
           let upper = AttributedString.Index(bounds.upperBound, within: text) {
            text[lower..<upper].font = .system(size: 12, design: .monospaced).bold()
            text[lower..<upper].underlineStyle = .single
        }
        return text
    }

    @ViewBuilder
    static func content(_ help: SignatureHelp, model: SignatureHelpModel?, resized: @escaping () -> Void) -> some View {
        let signature = help.signatures[help.activeSignature]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if help.signatures.count > 1 {
                    Button { cycle(model, by: -1); resized() } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                    Text("\(help.activeSignature + 1)/\(help.signatures.count)").foregroundStyle(.secondary).monospacedDigit()
                    Button { cycle(model, by: 1); resized() } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                }
                Text(label(help))
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            let parameterDoc = help.highlighted.flatMap { range in signature.parameters.first { $0.range == range }?.documentation }
            if let parameterDoc, !parameterDoc.isEmpty {
                Text(parameterDoc).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let documentation = signature.documentation, !documentation.isEmpty {
                Text(documentation.components(separatedBy: "\n").prefix(4).joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: maxWidth - 16, alignment: .leading)
    }

    private static func cycle(_ model: SignatureHelpModel?, by offset: Int) {
        guard let model, var help = model.help else { return }
        help.activeSignature = (help.activeSignature + offset + help.signatures.count) % help.signatures.count
        model.help = help
    }
}
