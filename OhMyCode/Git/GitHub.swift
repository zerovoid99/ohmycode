import AppKit

/// A pull request in GitHub's list.
struct PullRequest: Identifiable, Decodable, Equatable, Sendable {
    struct Author: Decodable, Equatable, Sendable { let login: String }

    let number: Int
    let title: String
    let author: Author
    let headRefName: String
    let isDraft: Bool
    let url: String
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED (or empty).
    let reviewDecision: String?

    var id: Int { number }

    var reviewLabel: String? {
        switch reviewDecision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Review required"
        default: nil
        }
    }
}

/// One pull request, opened: its description, files, reviews and comments.
struct PullRequestDetails: Decodable, Equatable, Sendable {
    struct Comment: Decodable, Equatable, Sendable, Identifiable {
        let author: PullRequest.Author
        let body: String
        let createdAt: String?
        var id: String { (createdAt ?? "") + author.login + String(body.prefix(40)) }
    }

    struct Review: Decodable, Equatable, Sendable, Identifiable {
        let author: PullRequest.Author
        let body: String
        let state: String
        let submittedAt: String?
        var id: String { (submittedAt ?? "") + author.login + state }
    }

    struct File: Decodable, Equatable, Sendable, Identifiable {
        let path: String
        let additions: Int
        let deletions: Int
        var id: String { path }
    }

    let number: Int
    let title: String
    let body: String
    let author: PullRequest.Author
    let headRefName: String
    let baseRefName: String
    let url: String
    let state: String
    let isDraft: Bool
    let comments: [Comment]
    let reviews: [Review]
    let files: [File]
}

/// GitHub through its command-line tool, `gh` (which keeps the login).
enum GitHub {
    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "The GitHub CLI isn't installed. Install it with `brew install gh`, then run `gh auth login`."
            case .failed(let message): message
            }
        }
    }

    /// The `gh` to run (tests use a fake); nil finds it on the login shell's PATH.
    nonisolated(unsafe) static var executable: String?

    static let listFields = "number,title,author,headRefName,isDraft,url,reviewDecision"
    static let detailFields = "number,title,body,author,headRefName,baseRefName,url,state,isDraft,comments,reviews,files"

    /// Runs `gh` in a folder, off the main thread; its output, or its error message.
    static func run(_ arguments: [String], in directory: URL) async throws -> Data {
        let environment = await ShellEnvironment.shared.environment()
        let override = executable
        return try await ProcessIO.detached(priority: .userInitiated) {
            let process = Process()
            if let override {
                process.executableURL = URL(fileURLWithPath: override)
                process.arguments = arguments
            } else {
                let found = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
                    .first { FileManager.default.isExecutableFile(atPath: $0) }
                guard let found else { throw Failure.notInstalled }
                process.executableURL = URL(fileURLWithPath: found)
                process.arguments = arguments
            }
            process.currentDirectoryURL = directory
            var env = environment
            // Nothing can answer a prompt here; no colors, no update notices.
            env["GH_PROMPT_DISABLED"] = "1"
            env["NO_COLOR"] = "1"
            env["GH_NO_UPDATE_NOTIFIER"] = "1"
            env["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            let result = try ProcessIO.run(process, output: output, error: error, timeout: .seconds(60))
            guard result.status == 0 else {
                let message = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.failed(message.isEmpty ? "gh \(arguments.first ?? "") failed (\(result.status))." : message)
            }
            return result.output
        }
    }

    static func pullRequests(in directory: URL) async throws -> [PullRequest] {
        let data = try await run(["pr", "list", "--json", listFields, "--limit", "50"], in: directory)
        return try JSONDecoder().decode([PullRequest].self, from: data)
    }

    static func details(of number: Int, in directory: URL) async throws -> PullRequestDetails {
        let data = try await run(["pr", "view", String(number), "--json", detailFields], in: directory)
        return try JSONDecoder().decode(PullRequestDetails.self, from: data)
    }

    static func checkout(_ number: Int, in directory: URL) async throws {
        _ = try await run(["pr", "checkout", String(number)], in: directory)
    }

    /// Creates a pull request from the current branch; its URL.
    static func create(title: String, body: String, base: String?, draft: Bool, in directory: URL) async throws -> String {
        var arguments = ["pr", "create", "--title", title, "--body", body]
        if let base, !base.isEmpty { arguments += ["--base", base] }
        if draft { arguments.append("--draft") }
        let output = try await run(arguments, in: directory)
        let text = String(decoding: output, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last { $0.hasPrefix("https://") }.map(String.init) ?? text
    }
}

extension Workspace {
    /// Pull Requests: the repository's open pull requests (`gh pr list`).
    func refreshPullRequests() async {
        guard let root = rootURL else { return }
        isLoadingPullRequests = true
        defer { isLoadingPullRequests = false }
        do {
            pullRequests = try await GitHub.pullRequests(in: root)
            pullRequestError = nil
        } catch {
            pullRequests = nil
            pullRequestError = error.localizedDescription
        }
    }

    /// Opens one: its description, files, reviews and comments.
    func showPullRequest(_ number: Int) async {
        guard let root = rootURL else { return }
        do {
            openPullRequest = try await GitHub.details(of: number, in: root)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Checks out its branch (`gh pr checkout`), then reads git again.
    func checkoutPullRequest(_ number: Int) async {
        guard let root = rootURL else { return }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        do {
            try await GitHub.checkout(number, in: root)
            refreshGit()
            _ = await notify(.info, "Checked out pull request #\(number).", source: "GitHub")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// What a new pull request starts with: the last commit's subject and body.
    func pullRequestDraft() -> (title: String, body: String) {
        guard let repository = gitRepository,
              let data = Git.run(["log", "-1", "--format=%s%x00%b"], in: repository.root) else { return ("", "") }
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\u{0}")
        return (parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }

    /// Creates a pull request from the current branch, pushing it first if it has no upstream.
    /// Returns its URL.
    @discardableResult
    func createPullRequest(title: String, body: String, draft: Bool) async -> String? {
        guard let root = rootURL, let repository = gitRepository else { return nil }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        do {
            if let status = gitStatus, status.upstream == nil, let branch = status.branch {
                try await ProcessIO.detached { try Git.push(branch: branch, settingUpstreamTo: "origin", in: repository) }
            }
            let url = try await GitHub.create(title: title, body: body, base: nil, draft: draft, in: root)
            refreshGit()
            await refreshPullRequests()
            Task { _ = await notify(.info, "Created \(url)", source: "GitHub") }
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openOnGitHub(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
