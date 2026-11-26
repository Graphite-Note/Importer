/**
 * File: InflaterAndZipArchiveTests.swift
 * --------------------------------------
 * Layer: Tests
 * Description: The DEFLATE decoder on stored, fixed and dynamic blocks, whole and fed a byte at a time, and the zip
 *              reader on archives made by the tests (zip64, nested, unsafe names, damaged) and on Obsidian Importer's
 *              own Notion exports.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation
@testable import ImporterCore
import ImporterTestSupport
import Testing

/// Compressed with zlib's raw DEFLATE (window 15, memory level 9): the first at level 0 (stored blocks), the second
/// with the Z_FIXED strategy, the third at level 9 (a dynamic block).
private let repeatedSentence = String(repeating: "Notion pages become notes, nested pages become folders. ", count: 3)
private let storedVector = "AagAV/9Ob3Rpb24gcGFnZXMgYmVjb21lIG5vdGVzLCBuZXN0ZWQgcGFnZXMgYmVjb21lIGZvbGRlcnMuIE5vdGlvbiBwYWdlcyBiZWNvbWUgbm90ZXMsIG5lc3RlZCBwYWdlcyBiZWNvbWUgZm9sZGVycy4gTm90aW9uIHBhZ2VzIGJlY29tZSBub3RlcywgbmVzdGVkIHBhZ2VzIGJlY29tZSBmb2xkZXJzLiA="
private let fixedVector = "88svyczPUyhITE8tVkhKTc7PTVXIyy9JLdZRyEstLklNQZVKy89JSS0q1lPwo7M+AA=="
private let dynamicVector = "fdZPatxgDIfhfU/hE5RP/6UeIzcodJoMKUlJB3L9xlheWIvfbLyZFz7hR7af3j+39WN7vNy2vz+fb9vn/fGy3X/d3h733/fbx7b23/bn/vb6b3u8bx/7379/e/q6EKqiqK6V0JExyMhS8po5H5mAjCUsrlnJkSnIhDz8mnEcmaGsrOyaWR6Zg0zDSK9Z1pEFyMxUZByyZ0uQuYjxOKQeWYEsiIPGIa1vN1Ky3+6hhHo4Qk4yaA0ndvJCUMoWDyjZvghJWVw6pNA5H6JCK31QUe8OWaGMHFaiiRHCwh5rYKFzPqRF1Hlo0V4gQlyUTQeXaGWEvNhSH156PEZc9jUfXKRXiBEXd67BxZsZIy6hTINLT8dISzLJ0CK9RIy01Fo2tHgrY6SlomJoqVbGSMuyrKFFeosYaSFJGlr8fEojLUwhQ0u1MkZauNyGFu75BHHZH++DizUzQVzUNAeXbGaCuJjoGlz4fA0hL07Cw4u1M0FevFiHl2xngrxEkA8vdM6HvKStHF6010iQl5K1hpdsZ5LwG6J4eKFzPuRlZerwol979B8="
private let dynamicText = (0..<40).map { index in
    let identifier = String(format: "%05d", index * 7919 % 100_000)
    return "Row \(index): the page with identifier \(identifier) links to row \(index * 31 % 97).\n"
}.joined()

private func inflate(_ compressed: Data, pieceSize: Int) throws -> Data {
    var inflater = Inflater()
    var output = Data()
    var offset = 0
    while offset < compressed.count {
        let end = min(offset + pieceSize, compressed.count)
        inflater.append(compressed[offset..<end])
        offset = end
        output.append(contentsOf: try inflater.inflate(isInputComplete: offset == compressed.count, maximumOutputCount: 97))
    }
    while !inflater.isFinished {
        output.append(contentsOf: try inflater.inflate(isInputComplete: true, maximumOutputCount: 97))
    }
    return output
}

@Suite("DEFLATE decoder")
struct InflaterTests {
    @Test("Stored, fixed and dynamic blocks decode, whole and fed one byte at a time",
          arguments: [(storedVector, repeatedSentence), (fixedVector, repeatedSentence), (dynamicVector, dynamicText)])
    func decodes(vector: String, expected: String) throws {
        let compressed = try #require(Data(base64Encoded: vector))
        #expect(String(decoding: try inflate(compressed, pieceSize: compressed.count), as: UTF8.self) == expected)
        #expect(String(decoding: try inflate(compressed, pieceSize: 1), as: UTF8.self) == expected)
    }

    @Test("Input cut short is an error, never a silent end")
    func truncatedInput() throws {
        let compressed = try #require(Data(base64Encoded: dynamicVector))
        #expect(throws: InflaterError.self) { try inflate(compressed.prefix(compressed.count / 2), pieceSize: 50) }
    }

    @Test("The reserved block type is refused")
    func reservedBlockType() {
        var inflater = Inflater()
        inflater.append([0b0000_0111])
        #expect(throws: InflaterError.reservedBlockType) { try inflater.inflate(isInputComplete: true) }
    }
}

@Suite("Zip archives")
struct ZipArchiveTests {
    private func read(_ archive: ZipArchive, _ path: String) async throws -> String {
        let entry = try #require(archive.entries.first(where: { $0.path == path }))
        return String(decoding: try await archive.contents(of: entry), as: UTF8.self)
    }

    @Test("Stored and deflated entries read back, with their names in UTF-8")
    func storedAndDeflated() async throws {
        let compressed = try #require(Data(base64Encoded: dynamicVector))
        let data = ZipBuilder(entries: [
            .stored("Ordner/Übersicht.md", text: "Grüße"),
            .deflated("rows.txt", contents: Data(dynamicText.utf8), deflated: compressed),
        ]).data
        let archive = try await ZipArchive.open(DataRandomAccessSource(data))
        #expect(archive.entries.map(\.path) == ["Ordner/Übersicht.md", "rows.txt"])
        #expect(try await read(archive, "Ordner/Übersicht.md") == "Grüße")
        #expect(try await read(archive, "rows.txt") == dynamicText)
    }

    @Test("A zip64 archive reads its sizes, offsets and entry count from the zip64 records")
    func zip64() async throws {
        let data = ZipBuilder(entries: [.stored("a.txt", text: "first"), .stored("b/c.txt", text: "second")], usesZip64: true).data
        let archive = try await ZipArchive.open(DataRandomAccessSource(data))
        #expect(archive.entries.map(\.path) == ["a.txt", "b/c.txt"])
        #expect(archive.entries.map(\.uncompressedSize) == [5, 6])
        #expect(try await read(archive, "b/c.txt") == "second")
    }

    @Test("A damaged entry fails its CRC-32 check")
    func checksumMismatch() async throws {
        var data = ZipBuilder(entries: [.stored("a.txt", text: "abcdef")]).data
        let position = try #require(data.range(of: Data("abcdef".utf8))).lowerBound
        data[position] = UInt8(ascii: "X")
        let archive = try await ZipArchive.open(DataRandomAccessSource(data))
        await #expect(throws: ZipArchiveError.checksumMismatch("a.txt")) { try await archive.contents(of: archive.entries[0]) }
    }

    @Test("Something that is not a zip, or a zip cut short, is refused")
    func notAZip() async throws {
        await #expect(throws: ZipArchiveError.notAZipArchive) {
            try await ZipArchive.open(DataRandomAccessSource(Data("<html></html>".utf8)))
        }
        let data = ZipBuilder(entries: [.stored("a.txt", text: "abcdef")]).data
        await #expect(throws: ZipArchiveError.notAZipArchive) {
            try await ZipArchive.open(DataRandomAccessSource(data.prefix(data.count - 30)))
        }
    }

    @Test("Paths that could reach outside the export and links are unsafe")
    func unsafeEntries() async throws {
        let data = ZipBuilder(entries: [
            .stored("../outside.md", text: "x"), .stored("/absolute.md", text: "x"), .stored("a\\b.md", text: "x"),
            .stored("C:/drive.md", text: "x"), .stored("link", Data("/etc".utf8), unixMode: 0o120777),
            .stored("fine/page.md", text: "x"),
        ]).data
        let archive = try await ZipArchive.open(DataRandomAccessSource(data))
        #expect(archive.entries.map(\.isUnsafe) == [true, true, true, true, true, false])
    }

    @Test("Names without the UTF-8 flag that are not UTF-8 read as code page 437")
    func codePage437() {
        #expect(ZipArchive.decodeName(Data([0x81, 0x62, 0x65, 0x72]), isUTF8: false) == "über")
        #expect(ZipArchive.decodeName(Data("naïve".utf8), isUTF8: false) == "naïve")
    }

    @Test("Obsidian Importer's HTML export: a zip holding a deflated Part-1 zip, read through temporary storage")
    func nestedNotionExport() async throws {
        let url = fixturesFolder.appendingPathComponent("Notion/notion-testspace.zip")
        let tree = try await ExportFileTree.reading(zipArchives: [try FileRandomAccessSource(url: url)],
                                                    named: ["notion-testspace.zip"], temporaryStorage: MemoryTemporaryStorage())
        #expect(tree.files.count == 10)
        #expect(tree.skippedEntries.isEmpty)
        let page = try #require(tree.files.first(where: { $0.name == "Block Reference 1580080aa5a38194a9c0e77779ee82d5.html" }))
        #expect(page.pathComponents.count == 3)
        let html = String(decoding: try await page.contents(), as: UTF8.self)
        #expect(html.hasPrefix("<html><head>"))
        #expect(html.hasSuffix("</body></html>"))
        #expect(html.utf8.count == 27_340)
    }

    @Test("A nested zip stored without compression is read where it lies, and folder temporary storage cleans up")
    func storedNestedZip() async throws {
        let inner = ZipBuilder(entries: [.stored("Export/Page 0123456789abcdef0123456789abcdef.html", text: "<p>x</p>")]).data
        let outer = ZipBuilder(entries: [.stored("Export-Part-1.zip", inner), .stored("__MACOSX/._Export", text: "noise")]).data
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("importer-tests-\(UUID().uuidString)")
        let storage = try FolderTemporaryStorage(folder: folder)
        let tree = try await ExportFileTree.reading(zipArchives: [DataRandomAccessSource(outer)], named: ["export.zip"],
                                                    temporaryStorage: storage)
        #expect(tree.files.map(\.path) == ["Export/Page 0123456789abcdef0123456789abcdef.html"])
        #expect(String(decoding: try await tree.files[0].contents(), as: UTF8.self) == "<p>x</p>")
        await storage.removeAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        try FileManager.default.removeItem(at: folder)
    }
}
