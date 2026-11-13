import SwiftUI

/// Parts of the window chrome a theme can color.
enum ChromeRole {
    case sidebar, tabBar, statusBar, panel
}

extension View {
    /// The theme's color for `role`, or the system look (`fallback`, e.g. `.bar`) for themes
    /// without chrome colors. Re-renders when the theme changes.
    func themedBackground(_ role: ChromeRole, fallback: some ShapeStyle) -> some View {
        modifier(ThemedBackground(role: role, fallback: AnyShapeStyle(fallback)))
    }

    /// The editor's own background (active tab, empty editor area).
    func editorBackground() -> some View {
        background(Color(nsColor: EditorTheme.observed.background))
    }
}

private struct ThemedBackground: ViewModifier {
    let role: ChromeRole
    let fallback: AnyShapeStyle

    func body(content: Content) -> some View {
        if let chrome = EditorTheme.observed.chrome {
            let color: NSColor = switch role {
            case .sidebar: chrome.sidebar
            case .tabBar: chrome.tabBar
            case .statusBar: chrome.statusBar
            case .panel: chrome.panel
            }
            // Lists (file tree, search results) draw their own background unless told not to.
            content
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: color))
        } else {
            content.background(fallback)
        }
    }
}
