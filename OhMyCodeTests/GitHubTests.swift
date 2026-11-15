import AppKit
import Testing
@testable import Oh_My_Code

/// GitHub through a fake `gh`: a script that logs its arguments and answers with fixed JSON.
@MainActor
@Suite(.serialized) // `GitHub.executable` is shared
struct GitHubTests {
    private static let fake = #"""
    #!/bin/bash
    printf '%s\n' "$*" >> "$(dirname "$0")/calls.log"
    case "$1 $2" in
      "pr list") cat <<'JSON'
    [{"number":7,"title":"Add the parser","author":{"login":"ana"},"headRefName":"parser","isDraft":false,"url":"https://github.com/o/r/pull/7","reviewDecision":"APPROVED"},
     {"number":8,"title":"WIP: docs","author":{"login":"bo"},"headRefName":"docs","isDraft":true,"url":"https://github.com/o/r/pull/8","reviewDecision":""}]
    JSON
      ;;
      "pr view") cat <<'JSON'
    {"number":7,"title":"Add the parser","body":"Parses things.","author":{"login":"ana"},"headRefName":"parser","baseRefName":"main",
     "url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,
     "comments":[{"author":{"login":"bo"},"body":"Nice!","createdAt":"2026-01-01T00:00:00Z"}],
     "reviews":[{"author":{"login":"cy"},"body":"","state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],
     "files":[{"path":"parser.swift","additions":40,"deletions":2}]}
    JSON
      ;;
      "pr checkout") git checkout -q -b parser ;;
      "pr create") echo "Creating pull request..."; echo "https://github.com/o/r/pull/9" ;;
      *) echo "boom: $*" >&2; exit 1 ;;
    esac
    """#

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t"] + arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// A repository with a commit and a bare `origin`, and the fake `gh`.
    private func setUp() throws -> (Workspace, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "omc-gh-\(UUID().uuidString)").resolvingSymlinksInPath()
        let repo = base.appending(path: "repo"), origin = base.appending(path: "origin.git"), tools = base.appending(path: "tools")
        for folder in [repo, origin, tools] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try git(["init", "-q", "--bare"], in: origin)
        try git(["init", "-q", "-b", "main"], in: repo)
        try "a\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "Add a\n\nThe first file."], in: repo)
        try git(["remote", "add", "origin", origin.path], in: repo)
        let gh = tools.appending(path: "gh")
        try Self.fake.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        GitHub.executable = gh.path
        let workspace = Workspace()
        workspace.openFolder(repo)
        return (workspace, repo, tools)
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func listsOpensAndChecksOut() async throws {
        let (workspace, repo, _) = try setUp()
        defer { GitHub.executable = nil }
        await workspace.refreshPullRequests()
        #expect(workspace.pullRequests?.map(\.number) == [7, 8] && workspace.pullRequestError == nil)
        #expect(workspace.pullRequests?.first?.reviewLabel == "Approved" && workspace.pullRequests?.last?.isDraft == true)

        await workspace.showPullRequest(7)
        let details = try #require(workspace.openPullRequest)
        #expect(details.files.first?.path == "parser.swift" && details.comments.first?.body == "Nice!" && details.reviews.count == 1)

        await workspace.checkoutPullRequest(7)
        #expect(try await eventually { workspace.gitStatus?.branch == "parser" })
        _ = repo
    }

    @Test func createsFromTheBranchPushingItFirst() async throws {
        let (workspace, repo, tools) = try setUp()
        defer { GitHub.executable = nil }
        try git(["checkout", "-q", "-b", "feature"], in: repo)
        workspace.refreshGit()
        #expect(try await eventually { workspace.gitStatus?.branch == "feature" })
        let draft = workspace.pullRequestDraft()
        #expect(draft.title == "Add a" && draft.body == "The first file.")

        let url = await workspace.createPullRequest(title: "Add a", body: "The first file.", draft: true)
        #expect(url == "https://github.com/o/r/pull/9")
        // Pushed with an upstream, then created as a draft with the title and body.
        #expect(try await eventually { workspace.gitStatus?.upstream == "origin/feature" })
        let calls = try String(contentsOf: tools.appending(path: "calls.log"), encoding: .utf8)
        #expect(calls.contains("pr create --title Add a --body The first file. --draft"))
    }

    @Test func errorsAreShown() async throws {
        let (workspace, _, _) = try setUp()
        defer { GitHub.executable = nil }
        GitHub.executable = "/usr/bin/false"
        await workspace.refreshPullRequests()
        #expect(workspace.pullRequests == nil && workspace.pullRequestError?.isEmpty == false)
    }
}
