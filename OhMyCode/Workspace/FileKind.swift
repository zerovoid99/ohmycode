import Foundation
import UniformTypeIdentifiers

/// What a file is, for opening it: text goes to the editor, the rest to a viewer tab.
enum FileKind: String, Equatable, Sendable {
    case text, image, svg, pdf, binary
    /// A SQLite database (by its header): opens in the database explorer.
    case sqlite

    /// How many bytes are looked at to tell text from binary (as `EditorDocument` does).
    static let sniffLength = 8192

    /// Image formats AppKit draws, by extension (others are found by their type).
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns",
    ]

    /// By the extension first (images, SVG, PDF), then by the first bytes. An empty file is text
    /// (a new file is about to be written), whatever its name.
    static func detect(_ url: URL) -> FileKind {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return .text }
        if let kind = kind(forExtension: url.pathExtension) { return kind }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .text } // opening says why
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: sniffLength)) ?? Data()
        if head.starts(with: sqliteHeader) { return .sqlite }
        return isText(head, complete: size <= sniffLength) ? .text : .binary
    }

    /// The first 16 bytes of every SQLite database file.
    static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    /// The kind an extension alone settles, if it does.
    static func kind(forExtension pathExtension: String) -> FileKind? {
        let ext = pathExtension.lowercased()
        if ext == "svg" { return .svg }
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        // Other images the system knows (PSD, RAW…), unless they are text (XBM, SVGZ aside).
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image), !type.conforms(to: .text) {
            return .image
        }
        return nil
    }

    /// Whether the start of a file reads as text the editor opens: UTF-16 with a byte order
    /// mark, or UTF-8 without NUL bytes. `complete` says it's the whole file; otherwise a
    /// character cut off at the end of the sample doesn't count against it.
    static func isText(_ head: Data, complete: Bool) -> Bool {
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return true }
        if head.contains(0) { return false }
        if String(data: head, encoding: .utf8) != nil { return true }
        guard !complete else { return false }
        // Up to three bytes of a multi-byte character may be cut off.
        for cut in 1...3 where head.count > cut {
            if String(data: head.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }
}

/// The hex view's rows: 16 bytes each, as `offset  hex bytes  |ASCII|`.
enum HexDump {
    static let bytesPerRow = 16

    static func rowCount(fileSize: Int) -> Int {
        (fileSize + bytesPerRow - 1) / bytesPerRow
    }

    /// One row: the offset (8 hex digits, more for files past 4 GB), the bytes in two groups of
    /// eight (a short last row is padded so the ASCII column stays aligned), and the bytes as
    /// ASCII with anything unprintable as `.`.
    static func row(offset: Int, bytes: some Collection<UInt8>) -> String {
        var hex = ""
        var ascii = ""
        var index = 0
        for byte in bytes.prefix(bytesPerRow) {
            if index == 8 { hex += " " }
            hex += hexByte(byte) + " "
            ascii.append(byte >= 0x20 && byte < 0x7F ? Character(UnicodeScalar(byte)) : ".")
            index += 1
        }
        while index < bytesPerRow {
            if index == 8 { hex += " " }
            hex += "   "
            index += 1
        }
        return offsetLabel(offset) + "  " + hex + " " + ascii
    }

    static func offsetLabel(_ offset: Int) -> String {
        let digits = String(offset, radix: 16)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    private static let digits = Array("0123456789abcdef")

    private static func hexByte(_ byte: UInt8) -> String {
        String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}

/// Reads a file in pages as the hex view scrolls, keeping a few: a 100 MB file never sits in
/// memory whole.
final class ChunkedFileReader {
    let url: URL
    let fileSize: Int
    static let pageSize = 64 * 1024
    static let maxPages = 8

    private var handle: FileHandle?
    private var pages: [Int: Data] = [:]
    /// Most recently used last.
    private var order: [Int] = []
    /// Pages read from disk so far (tests check reading stays lazy).
    private(set) var pagesRead = 0

    init(url: URL) {
        self.url = url
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        handle = try? FileHandle(forReadingFrom: url)
    }

    deinit { try? handle?.close() }

    /// Up to `count` bytes at `offset` (fewer at the end of the file).
    func bytes(at offset: Int, count: Int) -> Data {
        guard offset >= 0, offset < fileSize, count > 0 else { return Data() }
        let end = min(offset + count, fileSize)
        var result = Data()
        var position = offset
        while position < end {
            let pageIndex = position / Self.pageSize
            guard let page = page(pageIndex), !page.isEmpty else { break }
            let start = position - pageIndex * Self.pageSize
            let stop = min(page.count, end - pageIndex * Self.pageSize)
            guard start < stop else { break }
            result.append(page[page.startIndex + start ..< page.startIndex + stop])
            position = pageIndex * Self.pageSize + stop
        }
        return result
    }

    /// The text of hex row `row`.
    func row(_ row: Int) -> String {
        let offset = row * HexDump.bytesPerRow
        return HexDump.row(offset: offset, bytes: bytes(at: offset, count: HexDump.bytesPerRow))
    }

    private func page(_ index: Int) -> Data? {
        if let page = pages[index] {
            order.removeAll { $0 == index }
            order.append(index)
            return page
        }
        guard let handle else { return nil }
        do {
            try handle.seek(toOffset: UInt64(index * Self.pageSize))
            let data = try handle.read(upToCount: Self.pageSize) ?? Data()
            pagesRead += 1
            pages[index] = data
            order.append(index)
            if order.count > Self.maxPages { pages[order.removeFirst()] = nil }
            return data
        } catch {
            return nil
        }
    }
}
