import AppKit
import Observation
import SwiftUI

/// The merge editor: a file's conflicts one by one, with both sides (and the base, when git
/// kept it) side by side; choosing a side for each shows the resulting file, applied in one step.
@MainActor
@Observable
final class MergeSession: Identifiable {
    enum Choice: String, CaseIterable, Identifiable {
        case current, incoming, both, bothIncomingFirst

        var id: String { rawValue }

        var title: String {
            switch self {
            case .current: "Current"
            case .incoming: "Incoming"
            case .both: "Both"
            case .bothIncomingFirst: "Both, Incoming First"
            }
        }
    }

    struct Conflict: Identifiable {
        let id: Int
        let range: NSRange
        let current: String
        let base: String?
        let incoming: String
        let currentLabel: String
        let incomingLabel: String
        /// Lines before it in the file (1-based, for display).
        let line: Int
    }

    let id = UUID()
    let document: EditorDocument
    /// The text the conflicts were read from (applying checks it hasn't changed).
    let text: String
    let conflicts: [Conflict]
    var choices: [Int: Choice] = [:]

    init(document: EditorDocument) {
        self.document = document
        let string = document.textStorage.mutableString
        text = string as String
        // Read now: the document's own list is refreshed shortly after edits, so it can be stale.
        conflicts = ConflictParser.conflicts(in: string).enumerated().map { index, conflict in
            Conflict(id: index, range: conflict.range,
                     current: string.substring(with: conflict.current),
                     base: conflict.base.map { string.substring(with: $0) },
                     incoming: string.substring(with: conflict.incoming),
                     currentLabel: conflict.currentLabel, incomingLabel: conflict.incomingLabel,
                     line: document.lineIndex.line(containing: conflict.range.location) + 1)
        }
    }

    var unresolvedCount: Int { conflicts.count - choices.count }

    func text(of conflict: Conflict, choice: Choice) -> String {
        switch choice {
        case .current: conflict.current
        case .incoming: conflict.incoming
        case .both: conflict.current + conflict.incoming
        case .bothIncomingFirst: conflict.incoming + conflict.current
        }
    }

    func chooseAll(_ choice: Choice) {
        for conflict in conflicts { choices[conflict.id] = choice }
    }

    /// The edits for the chosen conflicts (unchosen ones keep their markers).
    var edits: [TextReplacement] {
        conflicts.compactMap { conflict in
            choices[conflict.id].map { TextReplacement(range: conflict.range, text: text(of: conflict, choice: $0)) }
        }
    }

    /// The file as it will be.
    var result: String {
        (try? TextReplacement.apply(edits, to: text)) ?? text
    }
}

extension Workspace {
    /// Git: Open Merge Editor, for the active file's conflicts.
    func openMergeEditor(_ target: EditorDocument? = nil) {
        guard let document = target ?? activeDocument,
              !ConflictParser.conflicts(in: document.textStorage.mutableString).isEmpty else { NSSound.beep(); return }
        pendingMerge = MergeSession(document: document)
    }

    /// Applies the merge editor's choices as one undo step. False when the file changed since.
    @discardableResult
    func applyMerge(_ session: MergeSession) -> Bool {
        pendingMerge = nil
        guard session.document.textStorage.mutableString.isEqual(to: session.text) else {
            errorMessage = "\(session.document.fileName) changed while merging: open the merge editor again."
            return false
        }
        guard !session.edits.isEmpty else { return true }
        do {
            try session.document.apply(session.edits, actionName: "Resolve Conflicts")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct MergeEditorView: View {
    @Bindable var session: MergeSession
    let workspace: Workspace
    @State private var selected = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Merge \(session.document.fileName)").font(.headline)
                Text(session.unresolvedCount == 0 ? "All \(session.conflicts.count) conflicts resolved"
                     : "\(session.unresolvedCount) of \(session.conflicts.count) conflicts left")
                    .foregroundStyle(session.unresolvedCount == 0 ? .green : .secondary)
                Spacer()
                Menu("Accept All") {
                    ForEach(MergeSession.Choice.allCases) { choice in
                        Button(choice.title) { session.chooseAll(choice) }
                    }
                }
                .fixedSize()
            }
            .padding(12)
            Divider()
            HSplitView {
                // The conflicts, one by one.
                List(session.conflicts, selection: Binding(get: { selected }, set: { selected = $0 ?? selected })) { conflict in
                    HStack {
                        Image(systemName: session.choices[conflict.id] == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(session.choices[conflict.id] == nil ? .orange : .green)
                        VStack(alignment: .leading) {
                            Text("Line \(conflict.line)")
                            Text(session.choices[conflict.id]?.title ?? "Unresolved").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(conflict.id)
                }
                .frame(minWidth: 150, idealWidth: 170, maxWidth: 220)

                VSplitView {
                    if let conflict = session.conflicts.first(where: { $0.id == selected }) {
                        sides(of: conflict)
                            .frame(minHeight: 180)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result").font(.subheadline.weight(.semibold))
                        ScrollView([.vertical, .horizontal]) {
                            Text(session.result)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                    }
                    .padding(8)
                    .frame(minHeight: 140)
                }
            }
            Divider()
            HStack {
                Text("Unresolved conflicts keep their markers. The change is one undo step; save when you're done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { workspace.pendingMerge = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { workspace.applyMerge(session) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.choices.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    private func sides(of conflict: MergeSession.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                side("Current", conflict.currentLabel, conflict.current, color: .green, choice: .current, conflict: conflict)
                if let base = conflict.base {
                    side("Base", "common ancestor", base, color: .gray, choice: nil, conflict: conflict)
                }
                side("Incoming", conflict.incomingLabel, conflict.incoming, color: .blue, choice: .incoming, conflict: conflict)
            }
            HStack {
                Text("Take:").foregroundStyle(.secondary)
                ForEach(MergeSession.Choice.allCases) { choice in
                    Toggle(choice.title, isOn: Binding(
                        get: { session.choices[conflict.id] == choice },
                        set: { session.choices[conflict.id] = $0 ? choice : nil }
                    ))
                    .toggleStyle(.button)
                }
                Spacer()
                Button("Next Unresolved") {
                    if let next = session.conflicts.first(where: { $0.id > conflict.id && session.choices[$0.id] == nil })
                        ?? session.conflicts.first(where: { session.choices[$0.id] == nil }) {
                        selected = next.id
                    }
                }
                .disabled(session.unresolvedCount == 0)
            }
        }
        .padding(8)
    }

    private func side(_ title: String, _ label: String, _ text: String, color: Color, choice: MergeSession.Choice?,
                      conflict: MergeSession.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let choice {
                    Button("Take") { session.choices[conflict.id] = choice }
                        .controlSize(.small)
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "(nothing)" : text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(session.choices[conflict.id] == choice && choice != nil ? color : .clear, lineWidth: 2))
        }
        .frame(maxWidth: .infinity)
    }
}
