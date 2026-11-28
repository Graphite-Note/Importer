/**
 * File: NotionFormattingTests.swift
 * ---------------------------------
 * Layer: Tests
 * Description: A made-up export for what an audit of real exports found written wrong: spaces at the edges of a
 *              link's label, an empty bookmark, styles Markdown could not open or close, a note starting with a rule,
 *              databases whose rows are elsewhere or missing, a page held twice, footnote links, formatted numbers, a
 *              list item without text, a picture held inside a page, `#` and `$` left as written, colors of blocks,
 *              links to pages by the identifier their address ends with, and names written composed.
 *
 * Authors: Bahey Shalash
 * Version: 0.4
 * Date: 28/11/2026
 */

import Foundation
import ImporterCore
import ImporterFileSystem
import ImporterTestSupport
@testable import NotionImport
import Testing

private let text = "a1000000000000000000000000000001"
private let journal = "a2000000000000000000000000000002"
private let things = "a3000000000000000000000000000003"
private let thing = "a4000000000000000000000000000004"
private let glossary = "a5000000000000000000000000000005"
private let index = "a6000000000000000000000000000006"
private let person = "a7000000000000000000000000000007"
private let client = "a8000000000000000000000000000008"

private func hyphenated(_ digits: String) -> String { NotionPageReader.hyphenatedIdentifier(digits)! }

/// A page as Notion's HTML export writes one.
private func page(_ identifier: String, title: String, header: String = "", body: String) -> String {
    """
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><title>\(title)</title></head><body>\
    <article id="\(hyphenated(identifier))" class="page sans"><header><h1 class="page-title">\(title)</h1>\(header)</header>\
    <div class="page-body">\(body)</div></article></body></html>
    """
}

private func databaseTable(rows: [(identifier: String, href: String, title: String)]) -> String {
    let body = rows.map { row in
        "<tr id=\"\(hyphenated(row.identifier))\"><td class=\"cell-title\"><a href=\"\(row.href)\">\(row.title)</a></td><td class=\"cell-x\">a note</td></tr>"
    }.joined()
    return "<table class=\"collection-content\"><thead><tr><th>Name</th><th>Text</th></tr></thead><tbody>\(body)</tbody></table>"
}

private let textBody = """
    <p id="b1" class="">Built on the<a href="https://skia.org"> Skia</a> library, word<a href="https://example.com/a"> </a>next.</p>\
    <figure id="b2"><a href="" class="bookmark source"><div class="bookmark-info"><div class="bookmark-text"><div class="bookmark-title"></div></div></div></a></figure>\
    <p id="b3" class="">Did it<em>.</em> Both <strong>So:</strong>\u{200B}Next and <strong>“</strong>We and a<strong>\u{00A0}</strong>b.</p>\
    <p id="b4" class="">The value of <em><strong>x = π, </strong></em>we get.</p>\
    <p id="b5" class="">A source<a href="https://example.com/notes#3">[3]</a> and https://example.org/council#decadal and #tag.</p>\
    <p id="b6" class="">It costs $5 and $10.</p><p id="b0" class="">But $a$ is not math here, &amp;nbsp; is text.</p>\
    <ul id="b7" class="bulleted-list"><li style="list-style-type:disc"><ul id="b8" class="bulleted-list"><li style="list-style-type:circle">neatly</li><li style="list-style-type:circle">handles</li></ul></li></ul>\
    <ul id="b9" class="bulleted-list"><li style="list-style-type:disc"></li></ul>\
    <figure id="c1"><div class="source"><a href="data:image/png;base64,iVBORw0KGgo=">Pasted picture</a></div></figure>\
    <h2 id="c2" class="block-color-yellow_background">Mission</h2>\
    <p id="c3" class="block-color-red_background">A red paragraph.</p>\
    <figure id="c4"><a href="https://example.com/read" class="bookmark source"><div class="bookmark-info"><div class="bookmark-text">\
    <div class="bookmark-title">Read</div><div class="bookmark-description">See http://asw.im/x.y for more. Second sentence.</div></div></div></a></figure>\
    <p id="c5" class="">See <a href="https://people.example.github.io/people/Some-Person-\(person)?pvs=21">Some Person</a>.</p>
    """

private let personProperties = """
    <table class="properties"><tbody><tr class="property-row property-row-number"><th>Confidence</th><td>100%</td></tr>\
    <tr class="property-row property-row-number"><th>Value</th><td>£42,000.00</td></tr></tbody></table>
    """

private func formattingExport() -> Data {
    ZipBuilder(entries: [
        .stored("Export/Text \(text).html", text: page(text, title: "Text", body: textBody)),
        .stored("Export/Journal \(journal).html", text: page(journal, title: "Journal", body: "<hr id=\"d1\"/><h2 id=\"d2\">Today</h2>")),
        // A database whose page file was renamed: its rows are in a folder of another name.
        .stored("Export/general-db.html", text: page(things, title: "Things", body: databaseTable(rows: [
            (thing, "Things%20\(things)/Thing%20\(thing).html", "Thing"),
        ]))),
        .stored("Export/Things \(things)/Thing \(thing).html", text: page(thing, title: "Thing", body: "<p id=\"e1\" class=\"\">A row.</p>")),
        // A database whose rows the export lacks: they link to notion.so.
        .stored("Export/Glossary \(glossary).html", text: page(glossary, title: "Glossary", body: databaseTable(rows: [
            ("b0000000000000000000000000000001", "https://www.notion.so/allocator-b0000000000000000000000000000001", "allocator"),
        ]))),
        // A page held twice: the backup copy comes first in the export's order, the index links to the other.
        .stored("Export/Index \(index).html", text: page(index, title: "Index", body: "<p id=\"f1\" class=\"\"><a href=\"people/Some%20Person%20\(person).html\">Some Person</a></p>")),
        .stored("Export/people bak/Some Person \(person).html", text: page(person, title: "Some Person", body: "<p id=\"g1\" class=\"\">Old.</p>")),
        .stored("Export/people/Some Person \(person).html", text: page(person, title: "Some Person", body: "<p id=\"g2\" class=\"\">Current.</p>")),
        .stored("Export/Café \(client).html", text: page(client, title: "Café", header: personProperties, body: "<p id=\"h1\" class=\"\">Client.</p>")),
    ]).data
}

@Suite("Formatting found by the audit of real exports")
struct NotionFormattingTests {
    private func importExport() async throws -> (TemporaryVault, NotionHTMLImportResult) {
        let tree = try await ExportFileTree.reading(zipArchives: [MemoryRandomAccessSource(Array(formattingExport()))],
                                                    named: ["Export.zip"], temporaryStorage: MemoryTemporaryStorage())
        let vault = try TemporaryVault()
        let options = NotionHTMLImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, exportName: "Export.zip",
                                              importDate: "2026-11-28", exportYear: 2026)
        let result = try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vault.folder), options: options)
        return (vault, result)
    }

    @Test("Links keep the spaces around them, footnotes and bare addresses read as written, an empty bookmark is reported")
    func links() async throws {
        let (vault, result) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Text.md")
        // A link whose text is a space is a linked space, as Notion shows it.
        #expect(note.contains("Built on the [Skia](https://skia.org) library, word[ ](https://example.com/a)next."), "\(note)")
        #expect(note.contains("A source[\\[3\\]](https://example.com/notes#3) and https://example.org/council#decadal and \\#tag."), "\(note)")
        #expect(!note.contains("<>"))
        #expect(note.contains("[Read](https://example.com/read)  \nSee http://asw.im/x.y for more.\n"), "\(note)")
        #expect(note.contains("See [[Some Person]]."), "\(note)")
        #expect(result.report.findings.contains { $0.message == "an empty bookmark, with no address, was left out" })
    }

    @Test("Styles open and close where CommonMark reads them, else are their HTML elements, and `$` is escaped only where math could start")
    func styles() async throws {
        let (vault, _) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Text.md")
        #expect(note.contains("Did it<em>.</em> Both <strong>So:</strong>\u{200B}Next and <strong>“</strong>We and a\u{00A0}b."), "\(note)")
        #expect(note.contains("The value of _**x = π,**_ we get."), "\(note)")
        #expect(note.contains("It costs $5 and $10.\n\nBut \\$a\\$ is not math here, \\&nbsp; is text."), "\(note)")
        // The yellow background is a highlight, other backgrounds a mark in their color.
        #expect(note.contains("## ==Mission==\n"), "\(note)")
    }

    @Test("A list item without text keeps its nested list under it, an empty item stays, a rule opening a note is ***")
    func listsAndRules() async throws {
        let (vault, result) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Text.md")
        #expect(note.contains("-\n    - neatly\n    - handles\n- \u{00A0}\n\n![[Notion/Picture 1.png]]"), "\(note)")
        #expect(try vault.text("Notion/Journal.md") == "***\n\n## Today\n")
        // A paragraph's background color is a mark of its text in that color.
        #expect(note.contains("<mark style=\"background:rgba(224, 90, 82, 0.25)\">A red paragraph.</mark>\n"), "\(note)")
        #expect(!result.report.findings.contains { $0.message.contains("color") })
    }

    @Test("A picture held inside the page is written beside the note and embedded")
    func heldPicture() async throws {
        let (vault, result) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Text.md")
        #expect(note.contains("![[Notion/Picture 1.png]]"), "\(note)")
        #expect(try Data(contentsOf: vault.folder.appendingPathComponent("Notion/Picture 1.png")) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(result.report.writtenCount(of: .attachment) == 1)
    }

    @Test("A base shows its rows' folder, a database without its rows is a table, a page held twice keeps the linked copy")
    func databasesAndCopies() async throws {
        let (vault, result) = try await importExport()
        defer { vault.remove() }
        #expect(try vault.text("Notion/Things.base").hasPrefix("filters: file.folder == \"Notion/Things\"\n"))
        #expect(vault.exists("Notion/Things/Thing.md"))
        let glossaryNote = try vault.text("Notion/Glossary.md")
        #expect(glossaryNote.contains("| Name | Text |\n| --- | --- |\n| [allocator](https://www.notion.so/allocator-b0000000000000000000000000000001) | a note |"), "\(glossaryNote)")
        #expect(!vault.exists("Notion/Glossary.base"))
        #expect(try vault.text("Notion/people/Some Person.md").contains("Current."))
        #expect(!vault.exists("Notion/people bak/Some Person.md"))
        let messages = result.report.findings.map(\.message)
        #expect(messages.contains { $0.hasPrefix("Export.zip/Export/people bak/Some Person") && $0.contains("holds the same page as") && $0.hasSuffix("(the two are different)") }, "\(messages)")
        #expect(messages.contains("the export holds none of the database's rows, so its table was written as a Markdown table"))
    }

    @Test("Formatted numbers are numbers, and names are written composed")
    func numbersAndNames() async throws {
        let (vault, result) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Café.md")
        #expect(note.hasPrefix("---\nConfidence: 1\nValue: 42000\n---\n"), "\(note)")
        #expect(result.report.findings.contains { $0.message == "numbers of the property “Confidence” are written as numbers, without Notion's percent format" })
        let names = try FileManager.default.contentsOfDirectory(atPath: vault.folder.appendingPathComponent("Notion").path)
        #expect(names.contains("Caf\u{E9}.md"), "\(names.map { Array($0.unicodeScalars) })")
    }
}
