import AppKit
import Testing
@testable import Oh_My_Code

/// Images, SVG, PDF and binary files open in viewer tabs (see FileViewer.swift).
@MainActor
struct FileViewerTests {
    private func makeFolder(_ files: [String: Data]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root
    }

    private static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private static func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='red'/></svg>".utf8)
    private static let binary = Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00] + Array(repeating: UInt8(0x41), count: 40))
    private static let utf16 = Data([0xFF, 0xFE]) + "héllo\nwörld\n".data(using: .utf16LittleEndian)!

    // MARK: Detection

    @Test func kindsAreToldApartByExtensionAndContent() throws {
        let root = try makeFolder([
            "a.png": Self.png(width: 2, height: 2), "b.JPG": Data([0xFF, 0xD8, 0xFF]), "c.gif": Data("GIF89a".utf8),
            "d.webp": Data([1]), "e.heic": Data([1]), "f.ico": Data([1]), "g.icns": Data([1]), "h.psd": Data([1]),
            "i.svg": Self.svg, "j.pdf": Self.pdf(pages: 1), "k.bin": Self.binary, "l.txt": Self.utf16,
            "m.png": Data(), "n.swift": Data("let x = 1\n".utf8), "o.dat": Data([0x66, 0xE9, 0x20, 0x6F]), // Latin-1, not UTF-8
            "p": Self.binary, "q.ts": Data("export const x = 1\n".utf8),
        ])
        let expected: [String: FileKind] = [
            "a.png": .image, "b.JPG": .image, "c.gif": .image, "d.webp": .image, "e.heic": .image, "f.ico": .image,
            "g.icns": .image, "h.psd": .image, "i.svg": .svg, "j.pdf": .pdf, "k.bin": .binary, "l.txt": .text,
            "m.png": .text, "n.swift": .text, "o.dat": .binary, "p": .binary, "q.ts": .text,
        ]
        for (name, kind) in expected {
            #expect(FileKind.detect(root.appending(path: name)) == kind, "\(name)")
        }
    }

    @Test func aCharacterCutOffByTheSampleIsStillText() {
        // "é" is two bytes; the sample ends between them.
        let text = Data(String(repeating: "a", count: FileKind.sniffLength - 1).utf8) + Data("é".utf8)
        #expect(FileKind.isText(text.prefix(FileKind.sniffLength), complete: false))
        #expect(!FileKind.isText(text.prefix(FileKind.sniffLength), complete: true))
        #expect(FileKind.isText(Data([0xFE, 0xFF, 0x00, 0x41]), complete: true)) // UTF-16 BE with BOM
    }

    // MARK: Opening

    @Test func eachKindOpensInItsOwnTab() throws {
        let root = try makeFolder(["a.png": Self.png(width: 3, height: 2), "b.svg": Self.svg, "c.pdf": Self.pdf(pages: 2),
                                   "d.bin": Self.binary, "e.txt": Data("text\n".utf8)])
        let workspace = Workspace()
        workspace.openFolder(root)
        let expected: [(String, FileViewer.Kind)] = [("a.png", .image), ("b.svg", .svg), ("c.pdf", .pdf), ("d.bin", .hex)]
        for (name, kind) in expected {
            workspace.open(fileAt: root.appending(path: name))
            let viewer = try #require(workspace.activeViewer, "\(name)")
            #expect(viewer.kind == kind && viewer.fileName == name)
            #expect(workspace.activeDocument == nil)
            #expect(workspace.tabInfo(viewer.id)?.title == name)
        }
        #expect(workspace.documents.isEmpty && workspace.viewers.count == 4)
        workspace.open(fileAt: root.appending(path: "e.txt"))
        #expect(workspace.activeDocument?.fileName == "e.txt" && workspace.activeViewer == nil)
        // Opening a viewer's file again shows its tab rather than a second one.
        workspace.open(fileAt: root.appending(path: "a.png"))
        #expect(workspace.viewers.count == 4 && workspace.activeViewer?.fileName == "a.png")
        #expect(workspace.activeGroup.documentIDs.count == 5)
        #expect(workspace.recentFiles.first?.lastPathComponent == "a.png")
    }

    @Test func textThatIsntUTF8PastTheSampleOpensInTheHexView() throws {
        let text = Data(String(repeating: "a", count: FileKind.sniffLength + 10).utf8) + Data([0xE9, 0x0A])
        let root = try makeFolder(["latin1.txt": text])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "latin1.txt"))
        #expect(workspace.activeViewer?.kind == .hex && workspace.documents.isEmpty)
        #expect(workspace.errorMessage == nil)
    }

    @Test func utf16TextIsEditedAndSavedAsUTF16() throws {
        let root = try makeFolder(["u.txt": Self.utf16])
        let url = root.appending(path: "u.txt")
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: url)
        let document = try #require(workspace.activeDocument)
        #expect(document.textStorage.string == "héllo\nwörld\n")
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "¡")
        #expect(workspace.save(document))
        #expect(try Data(contentsOf: url) == Data([0xFF, 0xFE]) + "¡héllo\nwörld\n".data(using: .utf16LittleEndian)!)
    }

    @Test func openAsTextPutsAnEditorInTheViewersTab() throws {
        let root = try makeFolder(["a.svg": Self.svg, "b.bin": Self.binary, "c.txt": Data("c".utf8)])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.svg"))
        workspace.open(fileAt: root.appending(path: "c.txt"))
        let svg = try #require(workspace.viewer(matching: root.appending(path: "a.svg")))
        let document = try #require(workspace.openAsText(svg))
        #expect(document.textStorage.string == String(data: Self.svg, encoding: .utf8))
        #expect(workspace.activeDocument === document && workspace.viewers.isEmpty)
        #expect(workspace.activeGroup.documentIDs.first == document.id) // the viewer's place
        // From the editor, the picture is one click away again (beside it).
        workspace.openPreview(of: document)
        #expect(workspace.activeViewer?.kind == .svg)
        #expect(workspace.activeGroup.documentIDs.firstIndex(of: workspace.activeViewer!.id) == 1)

        workspace.open(fileAt: root.appending(path: "b.bin"))
        let hex = try #require(workspace.activeViewer)
        let binary = try #require(workspace.openAsText(hex))
        #expect(binary.textStorage.length > 0 && workspace.activeDocument === binary)
        #expect(workspace.viewer(matching: root.appending(path: "b.bin")) == nil)
    }

    // MARK: Tabs

    @Test func viewerTabsCloseSplitAndMove() throws {
        let root = try makeFolder(["a.png": Self.png(width: 1, height: 1), "b.txt": Data("b".utf8)])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "b.txt"))
        workspace.open(fileAt: root.appending(path: "a.png"))
        let viewer = try #require(workspace.activeViewer)
        workspace.splitEditor()
        #expect(workspace.groups.count == 2 && workspace.activeViewer === viewer)
        // Closing it in one group leaves the other's.
        workspace.closeTab(viewer.id, in: workspace.activeGroup)
        #expect(workspace.groups.count == 1 && workspace.viewers.count == 1)
        workspace.activeDocumentID = viewer.id
        workspace.moveActiveEditor(by: 1)
        #expect(workspace.groups.count == 2 && workspace.activeViewer === viewer)
        workspace.closeTab(viewer.id, in: workspace.activeGroup)
        #expect(workspace.viewers.isEmpty && workspace.groups.count == 1)
        #expect(workspace.tabInfo(viewer.id) == nil)
    }

    @Test func aViewerTabComesBackWithTheSession() throws {
        let root = try makeFolder(["a.png": Self.png(width: 1, height: 1), "b.txt": Data("b".utf8), "c.pdf": Self.pdf(pages: 1)])
        let first = Workspace()
        first.openFolder(root)
        first.open(fileAt: root.appending(path: "a.png"))
        first.open(fileAt: root.appending(path: "b.txt"))
        first.open(fileAt: root.appending(path: "c.pdf"))
        first.keepSession(wasOpen: true, force: true)
        let stored = try #require(SessionStore.shared.read(first.sessionKey))
        #expect(stored.files.map { URL(fileURLWithPath: $0).lastPathComponent } == ["a.png", "b.txt", "c.pdf"])
        #expect(stored.activeFile.map { URL(fileURLWithPath: $0).lastPathComponent } == "c.pdf")

        let second = Workspace()
        second.openFolder(root)
        #expect(second.viewers.map(\.fileName).sorted() == ["a.png", "c.pdf"] && second.documents.count == 1)
        #expect(second.activeViewer?.fileName == "c.pdf")
        SessionStore.shared.remove(first.sessionKey)
    }

    @Test func textCommandsLeaveAViewerAlone() throws {
        let root = try makeFolder(["a.png": Self.png(width: 1, height: 1)])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.png"))
        let viewer = try #require(workspace.activeViewer)
        #expect(workspace.saveActive() == nil)
        workspace.saveAll()
        workspace.goToDefinition()
        workspace.showPalette(.goToLine)
        workspace.closePalette()
        let ids = ["file.save", "file.saveAll", "edit.find", "go.line", "go.symbol", "go.definition", "go.references",
                   "edit.format", "edit.rename", "edit.codeActions", "edit.fold", "edit.foldAll", "edit.hover",
                   "git.stageLines", "git.toggleBlame", "markdown.preview", "ai.triggerSuggestion", "ai.editSelection",
                   "debug.toggleBreakpoint", "edit.addNextOccurrence", "go.bracket", "view.toggleWordWrap"]
        for command in PaletteCommand.all where ids.contains(command.id) && command.isAvailable(workspace) {
            command.perform(workspace)
            workspace.closePalette()
        }
        #expect(workspace.activeViewer === viewer && workspace.documents.isEmpty)
        #expect(workspace.errorMessage == nil)

        // Zoom goes to the viewer's view, not the editor's font.
        final class Target: ViewerZoomable {
            var calls: [String] = []
            func zoomIn() { calls.append("in") }
            func zoomOut() { calls.append("out") }
            func zoomToFit() { calls.append("fit") }
            func zoomToActualSize() { calls.append("1:1") }
        }
        let target = Target()
        viewer.zoomTarget = target
        let fontSize = AppSettings.shared.editorFontSize
        Workspace.zoom(.zoomIn, in: workspace)
        Workspace.zoom(.zoomOut, in: workspace)
        Workspace.zoom(.fit, in: workspace)
        #expect(target.calls == ["in", "out", "fit"] && AppSettings.shared.editorFontSize == fontSize)

        // ⌘W's palette twin closes it.
        PaletteCommand.all.first { $0.id == "view.closeEditor" }?.perform(workspace)
        #expect(workspace.viewers.isEmpty)
    }

    @Test func viewersFollowTheirFile() async throws {
        let root = try makeFolder(["a.png": Self.png(width: 1, height: 1), "b.png": Self.png(width: 1, height: 1)])
        let url = root.appending(path: "a.png")
        let viewer = FileViewer(url: url, kind: .image)
        viewer.reloadIfChanged()
        #expect(viewer.version == 0)
        try Self.png(width: 20, height: 20).write(to: url)
        viewer.reloadIfChanged()
        #expect(viewer.version == 1)

        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: url)
        let moved = try #require(await workspace.rename(url, to: "renamed.png"))
        #expect(workspace.activeViewer?.url == moved && workspace.activeViewer?.fileName == "renamed.png")
        workspace.open(fileAt: root.appending(path: "b.png"))
        #expect(workspace.viewers.count == 2)
        let savedTrash = Workspace.moveToTrash, savedConfirm = Workspace.confirmTrash
        defer { Workspace.moveToTrash = savedTrash; Workspace.confirmTrash = savedConfirm }
        Workspace.moveToTrash = { try FileManager.default.removeItem(at: $0) } // not the real Trash
        Workspace.confirmTrash = { _ in true }
        workspace.trash([root.appending(path: "b.png")])
        #expect(workspace.viewers.map(\.fileName) == ["renamed.png"])
    }

    // MARK: Hex view

    @Test func hexRowsShowOffsetBytesAndASCII() {
        let full = HexDump.row(offset: 0x10, bytes: Array("Hello, world!\n\t\u{7F}".utf8))
        #expect(full == "00000010  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 0a 09 7f  Hello, world!...")
        // A short last row is padded so its ASCII lines up with the others'.
        let partial = HexDump.row(offset: 0x20, bytes: [0x00, 0x41, 0xFF])
        #expect(partial == "00000020  00 41 ff" + String(repeating: " ", count: 42) + ".A.")
        #expect(partial.count == full.count - 13)
        #expect(HexDump.offsetLabel(0x1_0000_0000) == "100000000")
        #expect(HexDump.rowCount(fileSize: 0) == 0 && HexDump.rowCount(fileSize: 16) == 1 && HexDump.rowCount(fileSize: 17) == 2)
    }

    @Test func aLargeFileIsReadInPagesAsNeeded() throws {
        let root = try makeFolder([:])
        let url = root.appending(path: "big.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let size = 100 * 1024 * 1024
        try handle.truncate(atOffset: UInt64(size)) // sparse: no 100 MB written
        try handle.seek(toOffset: UInt64(size / 2))
        try handle.write(contentsOf: Data("middle".utf8))
        try handle.close()

        let reader = ChunkedFileReader(url: url)
        #expect(reader.fileSize == size && HexDump.rowCount(fileSize: size) == size / 16)
        #expect(reader.pagesRead == 0)
        #expect(reader.row(size / 32).hasSuffix("middle.........."))
        #expect(reader.row(size / 32 + 1).hasPrefix(HexDump.offsetLabel(size / 2 + 16)))
        #expect(reader.pagesRead == 1)
        // Across a page boundary, and past the end.
        let boundary = ChunkedFileReader.pageSize - 4
        #expect(reader.bytes(at: boundary, count: 8).count == 8 && reader.pagesRead == 3)
        #expect(reader.bytes(at: size - 3, count: 16).count == 3)
        #expect(reader.bytes(at: size, count: 16).isEmpty)
        // Only a few pages are kept.
        for page in 0..<20 { _ = reader.bytes(at: page * ChunkedFileReader.pageSize * 7, count: 1) }
        let before = reader.pagesRead
        _ = reader.bytes(at: 0, count: 1)
        #expect(reader.pagesRead == before + 1)
    }

    // MARK: Image view

    @Test func imagesFitTheWindowUntilZoomed() {
        let view = ImageScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var reported: CGFloat?
        view.onScaleChange = { reported = $0 }
        view.show(NSImage(size: NSSize(width: 800, height: 600)))
        #expect(abs(view.magnification - 0.5) < 0.01 && reported == view.magnification)
        view.zoomIn()
        #expect(abs(view.magnification - 0.625) < 0.01 && !view.fitsWindow)
        view.zoomToActualSize()
        #expect(abs(view.magnification - 1) < 0.01)
        view.zoomToFit()
        #expect(abs(view.magnification - 0.5) < 0.01 && view.fitsWindow)
        // A small image isn't blown up.
        view.show(NSImage(size: NSSize(width: 100, height: 50)))
        #expect(abs(view.magnification - 1) < 0.01)
    }

    @Test func imageFactsComeFromTheFile() throws {
        let url = URL(fileURLWithPath: "/tmp/x.png")
        let info = ImageFileInfo.read(Self.png(width: 3, height: 2), url: url)
        #expect(info.facts == ["3 × 2", "PNG"])
        #expect(ImageFileInfo.read(Self.svg, url: URL(fileURLWithPath: "/tmp/x.svg")).facts == ["SVG"])
    }
}
