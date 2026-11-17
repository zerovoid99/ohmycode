import SwiftUI

/// The Pull Requests sidebar: the repository's open pull requests (through `gh`), one opened,
/// or the form for a new one.
struct PullRequestsView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if workspace.isCreatingPullRequest {
                CreatePullRequestForm(workspace: workspace)
            } else if let details = workspace.openPullRequest {
                PullRequestDetailsView(workspace: workspace, details: details)
            } else {
                list
            }
        }
        .task(id: [workspace.rootURL?.path, workspace.selectedRepositoryID]) {
            if workspace.pullRequests == nil, workspace.pullRequestError == nil { await workspace.refreshPullRequests() }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pull Requests").font(.headline)
                Spacer()
                if workspace.isLoadingPullRequests { ProgressView().controlSize(.small) }
                Button { Task { await workspace.refreshPullRequests() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button { workspace.isCreatingPullRequest = true } label: { Image(systemName: "plus") }
                    .help("Create Pull Request from \(workspace.gitStatus?.branch ?? "this branch")")
                    .disabled(workspace.gitStatus?.branch == nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if let error = workspace.pullRequestError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
            } else if let pulls = workspace.pullRequests, pulls.isEmpty {
                Text("No open pull requests.").foregroundStyle(.secondary).padding(10)
            } else {
                List(workspace.pullRequests ?? []) { pull in
                    PullRequestRow(pull: pull, isCurrent: pull.headRefName == workspace.gitStatus?.branch)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await workspace.showPullRequest(pull.number) } }
                        .contextMenu {
                            Button("Check Out") { Task { await workspace.checkoutPullRequest(pull.number) } }
                            Button("Open on GitHub") { workspace.openOnGitHub(pull.url) }
                        }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct PullRequestRow: View {
    let pull: PullRequest
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("#\(pull.number)").foregroundStyle(.secondary).monospacedDigit()
                Text(pull.title).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(pull.author.login)
                Text(pull.headRefName).lineLimit(1).truncationMode(.middle)
                if pull.isDraft { Text("Draft").foregroundStyle(.orange) }
                if let review = pull.reviewLabel {
                    Text(review).foregroundStyle(pull.reviewDecision == "APPROVED" ? .green : .secondary)
                }
                if isCurrent { Image(systemName: "checkmark").help("Checked out") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct PullRequestDetailsView: View {
    let workspace: Workspace
    let details: PullRequestDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { workspace.openPullRequest = nil } label: { Label("Pull Requests", systemImage: "chevron.left") }
                Spacer()
                Button("Check Out") { Task { await workspace.checkoutPullRequest(details.number) } }
                    .disabled(details.headRefName == workspace.gitStatus?.branch)
                Button { workspace.openOnGitHub(details.url) } label: { Image(systemName: "safari") }
                    .help("Open on GitHub")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("#\(details.number) \(details.title)").font(.headline).textSelection(.enabled)
                    Text("\(details.author.login) wants to merge \(details.headRefName) into \(details.baseRefName)"
                         + (details.isDraft ? " (draft)" : "") + " · \(details.state.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !details.body.isEmpty {
                        Text(details.body).font(.callout).textSelection(.enabled)
                    }
                    if !details.files.isEmpty {
                        Section {
                            ForEach(details.files) { file in
                                HStack {
                                    Text(file.path).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("+\(file.additions)").foregroundStyle(.green)
                                    Text("−\(file.deletions)").foregroundStyle(.red)
                                }
                                .font(.caption.monospacedDigit())
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let root = workspace.repositoryRootURL ?? workspace.rootURL { workspace.open(fileAt: root.appending(path: file.path)) }
                                }
                                .help("Open \(file.path)")
                            }
                        } header: {
                            Text("\(details.files.count) files changed").font(.subheadline.weight(.semibold))
                        }
                    }
                    let reviews = details.reviews.filter { !$0.body.isEmpty || $0.state != "COMMENTED" }
                    if !reviews.isEmpty || !details.comments.isEmpty {
                        Text("Conversation").font(.subheadline.weight(.semibold))
                        ForEach(reviews) { review in
                            Remark(author: review.author.login, label: Self.label(review.state), text: review.body)
                        }
                        ForEach(details.comments) { comment in
                            Remark(author: comment.author.login, label: nil, text: comment.body)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func label(_ state: String) -> String {
        switch state {
        case "APPROVED": "approved"
        case "CHANGES_REQUESTED": "requested changes"
        case "COMMENTED": "commented"
        case "DISMISSED": "review dismissed"
        default: state.lowercased()
        }
    }
}

private struct Remark: View {
    let author: String
    let label: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(author).fontWeight(.semibold)
                if let label { Text(label).foregroundStyle(.secondary) }
            }
            .font(.caption)
            if !text.isEmpty { Text(text).font(.callout).textSelection(.enabled) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CreatePullRequestForm: View {
    let workspace: Workspace
    @State private var title = ""
    @State private var text = ""
    @State private var draft = false
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create Pull Request").font(.headline)
            Text("From \(workspace.gitStatus?.branch ?? "?")" + (workspace.gitStatus?.upstream == nil ? " (pushed first)" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Title", text: $title)
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Toggle("Draft", isOn: $draft)
            HStack {
                Button("Cancel") { workspace.isCreatingPullRequest = false }
                Spacer()
                if isCreating { ProgressView().controlSize(.small) }
                Button("Create") {
                    isCreating = true
                    Task {
                        if await workspace.createPullRequest(title: title, body: text, draft: draft) != nil {
                            workspace.isCreatingPullRequest = false
                        }
                        isCreating = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(10)
        .onAppear {
            let draft = workspace.pullRequestDraft()
            if title.isEmpty { title = draft.title }
            if text.isEmpty { text = draft.body }
        }
    }
}
