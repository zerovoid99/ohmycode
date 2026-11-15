import AppKit

/// When long lines wrap at the editor's edge instead of scrolling sideways.
enum WordWrap: String, CaseIterable, Identifiable {
    case off, on
    /// Markdown and plain text wrap; code doesn't.
    case prose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .prose: "Markdown and plain text"
        }
    }

    func wraps(_ language: SourceLanguage) -> Bool {
        switch self {
        case .off: false
        case .on: true
        case .prose: language == .markdown || language == .plaintext
        }
    }
}

extension EditorDocument {
    /// Whether its lines wrap: ⌥Z's choice for this file, else the setting's.
    var wrapsLines: Bool { wordWrapOverride ?? (projectSettings.wordWrap ?? AppSettings.shared.wordWrap).wraps(language) }
}

extension EditorController {
    var wrapsLines: Bool { document.wrapsLines }

    /// The text view's width: the visible width with word wrap; without it, as wide as the
    /// widest line (and its inlay hints), so lines don't wrap and the view scrolls sideways.
    /// (The container tracks the view: see `makeView`.)
    func updateTextWidth() {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        let visible = scrollView.contentSize.width
        var width = visible
        if !(appliedWordWrap ?? wrapsLines) {
            let column = (" " as NSString).size(withAttributes: [.font: EditorTheme.font]).width
            let padding = textView.textContainerInset.width * 2 + (textView.textContainer?.lineFragmentPadding ?? 0) * 2
            width = max(visible, ceil(CGFloat(document.longestLineColumns + 2) * column + padding + document.widestInlayHints))
        }
        guard abs(textView.frame.width - width) > 0.5 else { return }
        textView.minSize = NSSize(width: width, height: 0)
        textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }

    /// View: Toggle Word Wrap (⌥Z): for this file, in every editor showing it, until it's closed.
    func toggleWordWrap() {
        document.wordWrapOverride = !document.wrapsLines
        document.editors.forEach { $0.applyWordWrap() }
    }

    /// Lays the text out wrapped at the view's width, or as one row per line with a horizontal
    /// scroller.
    func applyWordWrap() {
        guard let textView, let container = textView.textContainer, let scrollView = textView.enclosingScrollView else { return }
        let wraps = wrapsLines
        guard wraps != appliedWordWrap else { return }
        appliedWordWrap = wraps
        let topLine = topVisibleLine
        _ = container
        scrollView.hasHorizontalScroller = !wraps
        updateTextWidth()
        if wraps { scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY)) }
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        textView.needsLayout = true
        // The same line stays at the top (heights above it changed).
        scrollLineToTop(topLine)
        gutterView.needsDisplay = true
        diagnosticsOverlay?.needsDisplay = true
        minimapView?.refresh()
        stickyView?.update()
    }
}
