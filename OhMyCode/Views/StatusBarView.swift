import SwiftUI

struct StatusBarView: View {
    let document: EditorDocument?

    var body: some View {
        HStack(spacing: 16) {
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
