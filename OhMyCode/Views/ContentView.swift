import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarItem? = .home

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection {
            case .home, .none:
                ContentUnavailableView(
                    "Oh My Code",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    description: Text("Welcome to OMC.")
                )
            case .projects:
                ContentUnavailableView("No Projects", systemImage: "folder")
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case home
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .projects: "Projects"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .projects: "folder"
        }
    }
}

#Preview {
    ContentView()
}
