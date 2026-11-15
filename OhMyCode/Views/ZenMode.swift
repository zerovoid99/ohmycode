import AppKit
import SwiftUI

/// Zen mode: only the text. The sidebar, tab bar, breadcrumbs, bottom panel and status bar
/// hide, the editor is centered at a readable width and (by default) the window goes full
/// screen. Leaving puts everything back as it was.
extension Workspace {
    /// What zen mode hid, to put back.
    struct ZenRestore: Equatable {
        var sidebar: NavigationSplitViewVisibility
        var isPanelVisible: Bool
        var wasFullScreen: Bool
    }

    /// The editor's width in zen mode (about 100 columns plus the gutter).
    static var zenEditorWidth: CGFloat {
        let column = (" " as NSString).size(withAttributes: [.font: EditorTheme.font]).width
        return ceil(column * 100 + 80)
    }

    var isZenMode: Bool { zenRestore != nil }

    /// View: Toggle Zen Mode (⌥⌘Z; Esc twice in the editor leaves it).
    func toggleZenMode() {
        if let restore = zenRestore {
            zenRestore = nil
            sidebarVisibility = restore.sidebar
            isTerminalVisible = restore.isPanelVisible
            if !restore.wasFullScreen, isWindowFullScreen { window?.toggleFullScreen(nil) }
        } else {
            zenRestore = ZenRestore(sidebar: sidebarVisibility, isPanelVisible: isTerminalVisible, wasFullScreen: isWindowFullScreen)
            sidebarVisibility = .detailOnly
            isTerminalVisible = false
            if AppSettings.shared.zenModeFullScreen, !isWindowFullScreen { window?.toggleFullScreen(nil) }
        }
        activeDocument?.editor?.focus()
    }

    private var isWindowFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    /// Esc in the editor with nothing else to dismiss: a second one soon after leaves zen mode.
    func zenEscape() -> Bool {
        guard isZenMode else { return false }
        let now = Date()
        if let last = lastZenEscape, now.timeIntervalSince(last) < 0.6 {
            lastZenEscape = nil
            toggleZenMode()
        } else {
            lastZenEscape = now
        }
        return true
    }
}

/// The editor area in zen mode: centered at a readable width on the editor's background.
struct ZenCentered<Content: View>: View {
    let isZen: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if isZen {
            content
                .frame(maxWidth: Workspace.zenEditorWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: EditorTheme.observed.background))
        } else {
            content
        }
    }
}
