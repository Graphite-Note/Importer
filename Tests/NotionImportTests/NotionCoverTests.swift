/**
 * File: NotionCoverTests.swift
 * ----------------------------
 * Layer: Tests
 * Description: A Notion page's cover written as the note's `banner` property, the one Graphite, Banners and Pixel
 *              Banner draw a cover from: from the HTML export a cover the export holds as a link to the copied picture
 *              and a cover from the web as its address, a database property called banner kept as it is, and from
 *              Notion's API a cover from the web as its address and a cover uploaded to Notion downloaded and linked.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import Foundation
import ImporterCore
import ImporterFileSystem
import ImporterTestSupport
@testable import NotionImport
import Testing

private let held = "a111111111111111aaaaaaaaaaaaaaaa"
private let web = "b222222222222222aaaaaaaaaaaaaaaa"
private let own = "c333333333333333aaaaaaaaaaaaaaaa"
private let root = "Export-1e3f2a8c-1b7d-4e0f-8a6b-5c4d3e2f1a0b"

/// A page as Notion's HTML export writes one, its cover first in the header as Notion puts it.
private func page(_ identifier: String, title: String, cover: String?, properties: String = "") -> String {
    let coverImage = cover.map { "<img class=\"page-cover-image\" src=\"\($0)\" style=\"object-position:center 50%\"/>" } ?? ""
    return """
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><title>\(title)</title></head><body>\
        <article id="\(NotionPageReader.hyphenatedIdentifier(identifier)!)" class="page sans"><header>\(coverImage)\
        <div class="page-header-icon page-header-icon-with-cover"><span class="icon">📘</span></div>\
        <h1 class="page-title">\(title)</h1>\(properties)</header><div class="page-body"><p id="p1" class="">Text.</p></div></article></body></html>
        """
}

@Suite("Notion page covers")
struct NotionCoverTests {
    @Test("A cover the export holds links to the copied picture, one from the web keeps its address, both as banner")
    func coversAsBanner() async throws {
        let ownBanner = "<table class=\"properties\"><tbody><tr class=\"property-row property-row-text\"><th>banner</th><td>chosen</td></tr></tbody></table>"
        let export = ZipBuilder(entries: [
            .stored("\(root)/Held \(held).html", text: page(held, title: "Held", cover: "Held%20\(held)/Mountain%20view.jpg")),
            .stored("\(root)/Held \(held)/Mountain view.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])),
            .stored("\(root)/Web \(web).html", text: page(web, title: "Web", cover: "https://www.notion.so/images/page-cover/gradients_8.png")),
            .stored("\(root)/Own \(own).html", text: page(own, title: "Own", cover: "https://example.com/cover.png", properties: ownBanner)),
        ]).data
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let tree = try await ExportFileTree.reading(zipArchives: [MemoryRandomAccessSource(Array(export))], named: ["Export.zip"],
                                                    temporaryStorage: MemoryTemporaryStorage())
        let options = NotionHTMLImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, exportName: "Export.zip",
                                              importDate: "2026-11-27", exportYear: 2026)
        _ = try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vault.folder), options: options)

        let heldNote = try vault.text("Notion/Held.md")
        #expect(heldNote.hasPrefix("---\nicon: 📘\nbanner: \"[[Mountain view.jpg]]\"\n---\n"), "\(heldNote)")
        #expect(vault.exists("Notion/Held/Mountain view.jpg"))
        let webNote = try vault.text("Notion/Web.md")
        #expect(webNote.contains("banner: https://www.notion.so/images/page-cover/gradients_8.png\n"), "\(webNote)")
        #expect(!heldNote.contains("cover:") && !webNote.contains("cover:"))
        // A property of the page called banner is the page's own, and the cover does not replace it.
        let ownNote = try vault.text("Notion/Own.md")
        #expect(ownNote.contains("banner: chosen\n"), "\(ownNote)")
        #expect(!ownNote.contains("example.com"))
    }

    @Test("From Notion's API a cover from the web keeps its address, one uploaded to Notion is downloaded and linked")
    func apiCoversAsBanner() async throws {
        let uploaded = "https://files.example.com/cover/Lake%20at%20dawn.jpg?X-Amz-Signature=2"
        var workspace = try FakeNotionWorkspace.make()
        func cover(_ page: String, _ value: JSONValue) {
            guard case .object(let members)? = workspace.pages[page] else { return }
            workspace.pages[page] = .object(members + [("cover", value)])
        }
        cover(FakeNotionWorkspace.examplePage, .object([("type", .string("external")),
                                                        ("external", .object([("url", .string("https://images.example.com/hills.png"))]))]))
        cover(FakeNotionWorkspace.filesPage, .object([("type", .string("file")),
                                                      ("file", .object([("url", .string(uploaded)), ("expiry_time", .string("2026-11-27T12:00:00.000Z"))]))]))
        workspace.files[uploaded] = [0xFF, 0xD8, 0xFF, 0xE0, 9]
        let clock = VirtualClock()
        let served = workspace
        let transport = ScriptedTransport(clock: clock) { request, _ in served.answer(request) }
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let options = NotionAPIImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, importDate: "2026-11-27")
        let result = try await NotionAPIImporter.importWorkspace(client: NotionAPIClient(transport: transport, clock: clock),
                                                                 into: FolderImportDestination(vaultFolder: vault.folder), options: options)
        #expect(result.stoppedBecause == nil)
        let example = try vault.text("Notion/Example page.md")
        #expect(example.hasPrefix("---\nnotion-id: \(FakeNotionWorkspace.examplePage)\nicon: 📘\nbanner: https://images.example.com/hills.png\n---\n"), "\(example)")
        let files = try vault.text("Notion/Files.md")
        #expect(files.hasPrefix("---\nnotion-id: \(FakeNotionWorkspace.filesPage)\nbanner: \"[[Notion/Files/Lake at dawn.jpg]]\"\n---\n"), "\(files)")
        #expect(try Data(contentsOf: vault.folder.appendingPathComponent("Notion/Files/Lake at dawn.jpg")) == Data([0xFF, 0xD8, 0xFF, 0xE0, 9]))
        #expect(!example.contains("cover:") && !files.contains("cover:"))
    }
}
