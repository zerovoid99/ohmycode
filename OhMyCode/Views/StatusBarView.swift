import SwiftUI

struct StatusBarView: View {
    let document: EditorDocument?
    var gitStatus: GitStatus?

    var body: some View {
        HStack(spacing: 16) {
            if let gitStatus {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(gitStatus.branch ?? "detached")
                    if gitStatus.ahead > 0 { Text("↑\(gitStatus.ahead)") }
                    if gitStatus.behind > 0 { Text("↓\(gitStatus.behind)") }
                    if gitStatus.changedFileCount > 0 {
                        Text("•\(gitStatus.changedFileCount)")
                            .help("\(gitStatus.changedFileCount) changed files")
                    }
                }
            }
            if document?.hasExternalChanges == true {
                Label("Changed on disk, your unsaved edits were kept", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let document {
                Text("Ln \(document.cursorLine), Col \(document.cursorColumn)")
                Text("\(document.lineCount) lines")
                Text("UTF-8")
                Text(document.language.displayName)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(.bar)
    }
}
