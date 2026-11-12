import AppKit
import GhosttyVt
import Observation

/// One shell in a pseudo-terminal, emulated by libghostty-vt. Lives on the main thread: the
/// Ghostty terminal isn't thread-safe, and VT parsing is fast enough to run where it's drawn.
@MainActor
@Observable
final class TerminalSession {
    struct KeyInput {
        var key: GhosttyKey
        var mods: GhosttyMods
        var consumedMods: GhosttyMods = 0
        var text: String?
        var unshiftedCodepoint: UInt32 = 0
        var action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS
    }

    private(set) var title: String
    private(set) var isRunning = true
    private(set) var exitCode: Int32?
    private(set) var columns: UInt16
    private(set) var rows: UInt16

    @ObservationIgnored let terminal: GhosttyTerminal
    @ObservationIgnored let renderState: GhosttyRenderState
    @ObservationIgnored private let keyEncoder: GhosttyKeyEncoder
    @ObservationIgnored private let keyEvent: GhosttyKeyEvent
    @ObservationIgnored private var process: PTYProcess?
    @ObservationIgnored private var cellSize = (width: UInt16(0), height: UInt16(0))
    /// Called after new output was parsed; the view schedules a redraw.
    @ObservationIgnored var onContentChange: (() -> Void)?

    enum SessionError: LocalizedError {
        case ghostty(String)
        var errorDescription: String? {
            switch self { case .ghostty(let what): "Terminal error: \(what)" }
        }
    }

    /// Starts the user's login shell in `directory`, or `command` when given (used by tests).
    init(directory: URL, command: [String]? = nil, columns: UInt16 = 80, rows: UInt16 = 24) throws {
        self.columns = columns
        self.rows = rows

        var terminal: GhosttyTerminal?
        var renderState: GhosttyRenderState?
        var keyEncoder: GhosttyKeyEncoder?
        var keyEvent: GhosttyKeyEvent?
        guard ghostty_terminal_new(nil, &terminal, columns, rows) == GHOSTTY_SUCCESS, let terminal,
              ghostty_render_state_new(nil, &renderState) == GHOSTTY_SUCCESS, let renderState,
              ghostty_key_encoder_new(nil, &keyEncoder) == GHOSTTY_SUCCESS, let keyEncoder,
              ghostty_key_event_new(nil, &keyEvent) == GHOSTTY_SUCCESS, let keyEvent
        else { throw SessionError.ghostty("could not create terminal") }
        self.terminal = terminal
        self.renderState = renderState
        self.keyEncoder = keyEncoder
        self.keyEvent = keyEvent

        let shell = Self.loginShell()
        let arguments = command ?? ["-" + (shell as NSString).lastPathComponent] // leading "-": login shell
        let executable = command?.first ?? shell
        title = (executable as NSString).lastPathComponent

        installCallbacks()
        var scrollback: Int = 10_000
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback)

        let process = try PTYProcess(
            executable: executable, arguments: arguments, environment: Self.environment(),
            directory: directory.path, size: .init(columns: columns, rows: rows)
        )
        process.onOutput = { [weak self] data in self?.feed(data) }
        process.onExit = { [weak self] code in self?.processDidExit(code) }
        self.process = process
    }

    isolated deinit {
        process?.terminate()
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    func terminate() {
        process?.terminate()
    }

    // MARK: Output

    func feed(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base.assumingMemoryBound(to: UInt8.self), buffer.count)
        }
        onContentChange?()
    }

    private func processDidExit(_ code: Int32) {
        isRunning = false
        exitCode = code
        feed(Data("\r\n[Process exited with code \(code)]\r\n".utf8))
    }

    // MARK: Input

    /// Encodes a key with the terminal's current modes (cursor keys, kitty flags…) and sends it.
    /// Returns false when the key produces no bytes.
    @discardableResult
    func send(_ input: KeyInput) -> Bool {
        let bytes = encode(input)
        guard !bytes.isEmpty else { return false }
        scrollToBottom()
        process?.write(bytes)
        return true
    }

    func encode(_ input: KeyInput) -> Data {
        ghostty_key_encoder_set_from_terminal(keyEncoder, terminal)
        ghostty_key_event_set_action(keyEvent, input.action)
        ghostty_key_event_set_key(keyEvent, input.key)
        ghostty_key_event_set_mods(keyEvent, input.mods)
        ghostty_key_event_set_consumed_mods(keyEvent, input.consumedMods)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, input.unshiftedCodepoint)

        let utf8 = Array((input.text ?? "").utf8)
        var buffer = [UInt8](repeating: 0, count: 128)
        var written = 0
        let result = utf8.withUnsafeBufferPointer { text in
            ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: text.baseAddress, len: text.count))
            return ghostty_key_encoder_encode(keyEncoder, keyEvent, &buffer, buffer.count, &written)
        }
        ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: nil, len: 0))
        guard result == GHOSTTY_SUCCESS else { return Data() }
        return Data(buffer.prefix(written))
    }

    /// Pastes text, bracketed when the program asked for it (mode 2004), with unsafe control
    /// bytes stripped by Ghostty.
    func paste(_ text: String) {
        var mode = GhosttyTerminalModeConfig(mode: Self.bracketedPasteMode, value: false)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode)

        var data = Array(text.utf8CString.dropLast()) // mutable; Ghostty sanitizes in place
        var output = [UInt8](repeating: 0, count: data.count + 16)
        var written = 0
        let result = data.withUnsafeMutableBufferPointer { input in
            ghostty_paste_encode(input.baseAddress, input.count, mode.value, &output, output.count, &written)
        }
        guard result == GHOSTTY_SUCCESS else { return }
        scrollToBottom()
        process?.write(Data(output.prefix(written)))
    }

    func sendText(_ text: String) {
        process?.write(Data(text.utf8))
    }

    // MARK: Viewport

    func resize(columns: UInt16, rows: UInt16, cellWidth: UInt16, cellHeight: UInt16) {
        guard columns > 0, rows > 0,
              columns != self.columns || rows != self.rows || cellWidth != cellSize.width || cellHeight != cellSize.height
        else { return }
        self.columns = columns
        self.rows = rows
        cellSize = (cellWidth, cellHeight)
        ghostty_terminal_resize(terminal, columns, rows, UInt32(cellWidth), UInt32(cellHeight))
        process?.resize(.init(columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight))
        onContentChange?()
    }

    func scrollViewport(byRows delta: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = delta
        ghostty_terminal_scroll_viewport(terminal, behavior)
        onContentChange?()
    }

    func scrollToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    /// Whether the running program wants mouse events (then wheel scrolling is the program's).
    var isMouseTrackingEnabled: Bool {
        var tracking = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    func setDefaultColors(foreground: GhosttyColorRgb, background: GhosttyColorRgb) {
        var fg = foreground, bg = background
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        onContentChange?()
    }

    // MARK: Selection & text

    /// Selects from one viewport cell to another (inclusive).
    func select(from start: (x: UInt16, y: UInt16), to end: (x: UInt16, y: UInt16)) {
        var startRef = GhosttyGridRef(), endRef = GhosttyGridRef()
        guard gridRef(start, &startRef), gridRef(end, &endRef) else { return }
        var selection = GhosttySelection(start: startRef, end: endRef, rectangle: false)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        onContentChange?()
    }

    func clearSelection() {
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        onContentChange?()
    }

    var hasSelection: Bool {
        var selection = GhosttySelection()
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    /// Plain text of the selection (unwrapped and trimmed, as Ghostty copies it), or of the
    /// whole screen when `selectionOnly` is false.
    func text(selectionOnly: Bool) -> String? {
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal) == GHOSTTY_SUCCESS, let formatter else { return nil }
        defer { ghostty_formatter_free(formatter) }
        var emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        var on = true
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &on)
        if selectionOnly {
            var selection = GhosttySelection()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
            else { return nil }
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &on)
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection)
        }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &buffer, &length) == GHOSTTY_SUCCESS, let buffer
        else { return nil }
        defer { ghostty_free(nil, buffer, length) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }

    private func gridRef(_ cell: (x: UInt16, y: UInt16), _ ref: inout GhosttyGridRef) -> Bool {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate.x = cell.x
        point.value.coordinate.y = UInt32(cell.y)
        return ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS
    }

    // MARK: Callbacks from the VT stream

    private func installCallbacks() {
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())

        // Responses to queries (cursor position, device attributes…) go back to the program.
        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data else { return }
            let session = Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()
            let bytes = Data(bytes: data, count: length)
            MainActor.assumeIsolated { session.process?.write(bytes) }
        }
        let titleChanged: GhosttyTerminalTitleChangedFn = { terminal, userdata in
            guard let userdata else { return }
            let session = Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()
            var title = GhosttyString()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS,
                  let pointer = title.ptr, title.len > 0 else { return }
            let text = String(decoding: UnsafeBufferPointer(start: pointer, count: title.len), as: UTF8.self)
            MainActor.assumeIsolated { session.title = text }
        }
        let bell: GhosttyTerminalBellFn = { _, _ in
            MainActor.assumeIsolated { NSSound.beep() }
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
    }

    // MARK: Environment

    private static let bracketedPasteMode: GhosttyMode = 2004 // DEC private mode (ANSI bit clear)

    private static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "OhMyCode"
        // Apps launched from Finder get no locale; without it shells mangle UTF-8 input.
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }
}
