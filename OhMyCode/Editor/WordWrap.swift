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
        if wraps {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
            container.widthTracksTextView = true
            container.size = NSSize(width: textView.bounds.width - textView.textContainerInset.width * 2,
                                    height: CGFloat.greatestFiniteMagnitude)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY))
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }
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
