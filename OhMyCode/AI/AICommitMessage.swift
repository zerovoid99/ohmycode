import Foundation
import Observation

extension Git {
    /// What a commit message is written from: the staged diff, or with nothing staged, every
    /// change (tracked files' diff against HEAD, untracked files by name). Cut to 30,000
    /// characters (see `AIPrompts.cappedDiff`). Nil when there's nothing to describe.
    static func diffForCommitMessage(in repository: Repository) -> (diff: String, allChanges: Bool)? {
        // No external diff tools or text conversions: only git's own diff is read.
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames"]
        func text(_ arguments: [String]) -> String {
            run(arguments, in: repository.root).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let staged = text(["diff", "--cached"] + options)
        if !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let numstat = text(["diff", "--cached", "--numstat", "--no-renames"])
            return (AIPrompts.cappedDiff(staged, numstat: numstat), false)
        }
        let hasHead = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: repository.root) != nil
        let base = hasHead ? ["diff", "HEAD"] : ["diff"]
        let diff = text(base + options)
        let numstat = text(base + ["--numstat", "--no-renames"])
        let untracked = text(["ls-files", "--others", "--exclude-standard", "--full-name", "-z", "--", ":/"])
            .split(separator: "\0").map(String.init)
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !untracked.isEmpty else { return nil }
        return (AIPrompts.cappedDiff(diff, numstat: numstat, extraFiles: untracked), true)
    }
}

/// Source Control's commit message, and writing one with AI from the changes (streamed into
/// the field).
@MainActor
@Observable
final class AICommitMessageModel {
    enum Phase: Equatable {
        case idle, generating
        case failed(String)
    }

    var message = ""
    private(set) var phase: Phase = .idle
    /// The last message was written from all changes: nothing was staged.
    private(set) var usedAllChanges = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// What the model last put in the field.
    @ObservationIgnored private var written: String?

    var isGenerating: Bool { phase == .generating }

    /// Writes a message for what's staged in `repository` (everything, with nothing staged).
    func generate(in repository: Git.Repository, branch: String?, settings: AISettings = .shared) {
        task?.cancel()
        written = message
        let provider: any AIProvider
        do {
            provider = try settings.makeProvider()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let previous = message
        phase = .generating
        task = Task { [weak self] in
            let changes = await Task.detached { Git.diffForCommitMessage(in: repository) }.value
            guard let self, !Task.isCancelled else { return }
            guard let changes else {
                self.phase = .failed("There are no changes to describe.")
                return
            }
            self.usedAllChanges = changes.allChanges
            let request = AIPrompts.commitMessageRequest(diff: changes.diff, allChanges: changes.allChanges, branch: branch,
                                                         model: settings.editModel)
            settings.requestStarted()
            defer { settings.requestEnded() }
            var raw = ""
            do {
                for try await piece in provider.stream(request) {
                    guard !Task.isCancelled else { return }
                    raw += piece
                    self.write(AIPrompts.stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard !Task.isCancelled else { return }
                let final = AIPrompts.sanitizeCommitMessage(raw)
                self.write(final.isEmpty ? previous : final)
                self.phase = final.isEmpty ? .failed("The model replied with an empty message.") : .idle
            } catch {
                guard !Task.isCancelled else { return }
                // Nothing came: what was typed comes back.
                self.write(raw.isEmpty ? previous : AIPrompts.sanitizeCommitMessage(raw))
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops writing: what came so far stays.
    func stop() {
        task?.cancel()
        task = nil
        if phase == .generating {
            write(AIPrompts.sanitizeCommitMessage(message))
            phase = .idle
        }
    }

    /// The field changed: typing in it clears an error (the model's own writes don't).
    func messageEdited() {
        guard message != written, case .failed = phase else { return }
        phase = .idle
    }

    private func write(_ text: String) {
        message = text
        written = text
    }

    /// Waits for the message (tests).
    func waitForReply() async { await task?.value }
}
