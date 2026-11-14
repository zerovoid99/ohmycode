import AppKit

extension Workspace {
    /// Gutter marks for the document's tests, and running them from there.
    func attachTests(to document: EditorDocument) {
        let url = document.url
        document.testMarks = { [weak self] in self?.testing.marks(for: url) ?? [:] }
        document.runTestAction = { [weak self] line in self?.testing.runTest(at: line, in: url) }
    }

    /// ⌘U: every test.
    func runAllTests() {
        testing.run(nil)
    }

    /// The test (or suite) the cursor is in.
    func runTestAtCursor() {
        guard let document = activeDocument, let item = testing.item(at: document.cursorLine - 1, in: document.url) else {
            NSSound.beep()
            return
        }
        testing.run([item])
    }

    func runTestsInCurrentFile() {
        guard let document = activeDocument, let file = testing.file(for: document.url) else { NSSound.beep(); return }
        testing.run([file])
    }

    /// Opens a test's declaration.
    func open(test item: TestItem) {
        open(fileAt: workspaceURL(for: item.url))
        activeDocument?.revealLine(item.line + 1)
        activeDocument?.editor?.focus()
    }

    /// Shows the output of the latest test run.
    func showTestOutput() {
        if let run = testing.runs.last { selectedTaskRunID = run.id }
        showTasks()
    }
}
