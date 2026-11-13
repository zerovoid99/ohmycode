import SwiftUI

/// Find in Files (⇧⌘F) sidebar panel.
struct SearchView: View {
    let model: SearchModel
    @FocusState private var queryFocused: Bool
    @State private var showsFilters = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    model.showsReplace.toggle()
                } label: {
                    Image(systemName: model.showsReplace ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .help("Toggle Replace (⇧⌘H)")
                TextField("Search", text: binding(\.query))
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                toggle("Aa", \.caseSensitive, help: "Match Case")
                toggle("ab", \.wholeWord, help: "Match Whole Word", underline: true)
                toggle(".*", \.regex, help: "Use Regular Expression")
                Button {
                    showsFilters.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.borderless)
                .help("Files to include/exclude")
            }
            if model.showsReplace {
                HStack(spacing: 4) {
                    Spacer().frame(width: 16)
                    TextField(model.options.regex ? "Replace ($1 for groups)" : "Replace", text: replacementBinding)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.replaceAll()
                    } label: {
                        Image(systemName: "text.badge.checkmark")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.results.isEmpty || model.isReplacing)
                    .help("Replace All")
                }
            }
            if showsFilters {
                TextField("Files to include (e.g. *.swift, Sources/)", text: binding(\.include))
                    .textFieldStyle(.roundedBorder)
                TextField("Files to exclude", text: binding(\.exclude))
                    .textFieldStyle(.roundedBorder)
            }
            summary
            List {
                ForEach(model.results) { result in
                    DisclosureGroup(isExpanded: .constant(true)) {
                        ForEach(result.matches) { match in
                            SearchMatchRow(match: match,
                                           replacement: model.showsReplace ? model.replacementPreview(for: match) : nil,
                                           onReplace: { model.replace(match, in: result) })
                                .onTapGesture { model.open(result, match) }
                        }
                    } label: {
                        SearchFileHeader(result: result,
                                         onReplace: model.showsReplace ? { model.replace(in: result) } : nil)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .onChange(of: model.focusRequest, initial: true) { _, _ in queryFocused = true }
    }

    @ViewBuilder private var summary: some View {
        HStack {
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            } else if model.options.query.isEmpty {
                Text(" ")
            } else if model.isSearching && model.results.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Text(model.results.isEmpty ? "No results"
                     : "\(model.matchCount) result\(model.matchCount == 1 ? "" : "s") in \(model.results.count) file\(model.results.count == 1 ? "" : "s")"
                     + (model.isTruncated ? " (limit reached)" : ""))
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var replacementBinding: Binding<String> {
        Binding(get: { model.replacement }, set: { model.replacement = $0 })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SearchOptions, Value>) -> Binding<Value> {
        Binding(get: { model.options[keyPath: keyPath] }, set: { model.options[keyPath: keyPath] = $0 })
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<SearchOptions, Bool>,
                        help: String, underline: Bool = false) -> some View {
        let isOn = model.options[keyPath: keyPath]
        return Button {
            model.options[keyPath: keyPath].toggle()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .underline(underline)
                .frame(width: 22, height: 20)
                .background(isOn ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A file's row in search and reference results.
struct SearchFileHeader: View {
    let result: SearchFileResult
    var onReplace: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text((result.path as NSString).lastPathComponent).lineLimit(1)
            Text((result.path as NSString).deletingLastPathComponent)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if isHovered, let onReplace {
                Button(action: onReplace) { Image(systemName: "text.badge.checkmark") }
                    .buttonStyle(.borderless)
                    .help("Replace All in File")
            }
            Text("\(result.matches.count)")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .background(.quaternary, in: Capsule())
        }
        .onHover { isHovered = $0 }
    }
}

/// One match: its line with the match highlighted, or with `replacement` shown as a diff.
struct SearchMatchRow: View {
    let match: SearchMatch
    var replacement: String?
    var onReplace: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            highlighted
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered, replacement != nil, let onReplace {
                Button(action: onReplace) { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Replace")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help("Line \(match.line + 1)")
    }

    private var highlighted: Text {
        let preview = match.preview as NSString
        let range = match.previewRange
        guard range.location >= 0, NSMaxRange(range) <= preview.length else { return Text(match.preview) }
        let before = preview.substring(to: range.location)
        let hit = preview.substring(with: range)
        let after = preview.substring(from: NSMaxRange(range))
        var hitText = AttributedString(hit)
        hitText.font = .system(size: 12, weight: .bold, design: .monospaced)
        guard let replacement else {
            hitText.backgroundColor = Color.orange.opacity(0.35)
            return Text(before) + Text(hitText) + Text(after)
        }
        hitText.backgroundColor = Color.red.opacity(0.25)
        hitText.strikethroughStyle = .single
        var newText = AttributedString(replacement.replacingOccurrences(of: "\n", with: "⏎"))
        newText.backgroundColor = Color.green.opacity(0.3)
        newText.font = .system(size: 12, weight: .bold, design: .monospaced)
        return Text(before) + Text(hitText) + Text(newText) + Text(after)
    }
}
