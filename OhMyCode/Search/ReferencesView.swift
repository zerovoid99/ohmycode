import SwiftUI

/// Find All References (⇧F12) results in the sidebar.
struct ReferencesView: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let references = workspace.references {
                HStack {
                    Text("\(references.count) \(references.noun)\(references.count == 1 ? "" : "s") \(references.noun == "reference" ? "to" : "of") ")
                        + Text(references.symbol).font(.system(.caption, design: .monospaced).bold())
                        + Text(" in \(references.results.count) file\(references.results.count == 1 ? "" : "s")")
                    Spacer()
                    Button {
                        workspace.references = nil
                        workspace.sidebarMode = .files
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear References")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                List {
                    ForEach(references.results) { result in
                        DisclosureGroup(isExpanded: .constant(true)) {
                            ForEach(result.matches) { match in
                                SearchMatchRow(match: match)
                                    .onTapGesture { workspace.open(result, match) }
                            }
                        } label: {
                            SearchFileHeader(result: result)
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView("No References", systemImage: "link",
                                       description: Text("Use Find All References (⇧F12) on a symbol."))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}
