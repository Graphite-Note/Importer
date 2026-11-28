/**
 * File: NotionMadeUpExportTests.swift
 * -----------------------------------
 * Layer: Tests
 * Description: A Notion HTML export made by the test, for what Obsidian Importer's material lacks: a database with
 *              typed properties and a row only its CSV holds, an inline database, a toggle, a callout with an icon,
 *              columns, a title longer than a file name allows, two pages of one title, an export in two parts with a
 *              nested zip, a path that leaves the export, and a vault that already has some of the names and types.
 *
 * Authors: Bahey Shalash
 * Version: 0.3
 * Date: 28/11/2026
 */

import Foundation
import ImporterCore
import ImporterFileSystem
import ImporterTestSupport
@testable import NotionImport
import Testing

private let course = "1111111111111111aaaaaaaaaaaaaaaa"
private let week = "2222222222222222aaaaaaaaaaaaaaaa"
private let lectures = "3333333333333333aaaaaaaaaaaaaaaa"
private let intro = "4444444444444444aaaaaaaaaaaaaaaa"
private let long = "5555555555555555aaaaaaaaaaaaaaaa"
private let notesOne = "6666666666666666aaaaaaaaaaaaaaaa"
private let notesTwo = "7777777777777777aaaaaaaaaaaaaaaa"
private let weekNotes = "8888888888888888aaaaaaaaaaaaaaaa"
private let root = "Export-0e3f2a8c-1b7d-4e0f-8a6b-5c4d3e2f1a0b"
private let longTitle = String(repeating: "A very long title of a lecture ", count: 8) + "end"

private func hyphenated(_ digits: String) -> String {
    NotionPageReader.hyphenatedIdentifier(digits)!
}

/// A page as Notion's HTML export writes one, on one line from `<article>` on.
private func page(_ identifier: String, title: String, header: String = "", body: String) -> String {
    """
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><title>\(title)</title><style>
    body { white-space: pre-wrap; }
    </style></head><body><article id="\(hyphenated(identifier))" class="page sans"><header>\(header)<h1 class="page-title">\(title)</h1><p class="page-description"></p></header><div class="page-body">\(body)</div></article></body></html>
    """
}

private func property(_ type: String, _ name: String, _ value: String) -> String {
    "<tr class=\"property-row property-row-\(type)\"><th><span class=\"icon property-icon\"><svg class=\"types\"></svg></span>\(name)</th><td>\(value)</td></tr>"
}

private func column(_ type: String, _ name: String) -> String {
    "<th><span class=\"icon property-icon\"><svg viewBox=\"0 0 14 14\" class=\"\(type)\"><path d=\"M0,0\"></path></svg></span>\(name)</th>"
}

private let lecturesTable = """
    <table class="collection-content"><thead><tr>\(column("typesTitle", "Name"))\(column("typesDate", "Date"))\(column("typesCheckbox", "Done"))\(column("typesMultipleSelect", "Tags"))\(column("typesFile", "Slides"))</tr></thead><tbody><tr id="\(hyphenated(intro))"><td class="cell-title"><a href="Lectures%20\(lectures)/Intro%20\(intro).html">Intro</a></td><td class="cell-abc"><time>@March 4, 2024 2:15 PM</time></td><td class="cell-def"><div class="checkbox checkbox-on"></div></td><td class="cell-ghi"><span class="selected-value select-value-color-blue">first week</span></td><td class="cell-jkl"><a href="Lectures%20\(lectures)/Intro%20\(intro)/slides.pdf">slides.pdf</a></td></tr></tbody></table>
    """

private let coursePage = page(course, title: "Course", header: "<div class=\"page-header-icon undefined\"><span class=\"icon\">🎓</span></div>", body: """
    <p id="a1" class="">See <a href="Course%20\(course)/Week%201%20\(week).html">Week 1</a> and <a href="Course%20\(course)/Long%20title%20\(long).html">the long one</a>.</p>\
    <ul id="a2" class="toggle"><li><details open=""><summary>Hidden part</summary><p id="a3" class="">Inside the toggle.</p></details></li></ul>\
    <figure class="block-color-default_background callout" style="white-space:pre-wrap;display:flex" id="a4"><div style="font-size:1.5em"><span class="icon">⚠️</span></div><div style="width:100%"><p id="a5" class="">Mind the <strong>deadline</strong></p><p id="a6" class="">It is on Friday.</p></div></figure>\
    <div id="a7" class="column-list"><div id="a8" style="width:50%" class="column"><p id="a9" class="">Left</p></div><div id="b1" style="width:50%" class="column"><p id="b2" class="">Right</p></div></div>\
    <pre id="b3" class="code"><code class="language-C++">int main() { return 0; }</code></pre>\
    <p id="b4" class="">Energy <span class="notion-text-equation-token"><span></span><span><span class="katex"><span class="katex-mathml"><math><semantics><mrow></mrow><annotation encoding="application/x-tex"> E = mc^2 </annotation></semantics></math></span></span></span><span>﻿</span></span> costs $5 and #tag.</p>\
    <figure id="b5" class="image"><a href="Course%20\(course)/diagram.png"><img style="width:400px" src="Course%20\(course)/diagram.png"/></a></figure>\
    <div id="\(hyphenated(lectures))" class="collection-content"><h4 class="collection-title">Lectures</h4>\(lecturesTable)</div>\
    <figure id="b6" class="link-to-page"><a href="Course%20\(course)/\(notesOne == "" ? "" : "Notes%20\(notesOne).html")"><span class="icon">📝</span>Notes</a></figure>
    """)

private let weekPage = page(week, title: "Week 1", body: "<p id=\"c1\" class=\"\">Back to <a href=\"../Course%20\(course).html\">the course</a>.</p>")
private let lecturesPage = page(lectures, title: "Lectures", body: lecturesTable)
private let introPage = page(intro, title: "Intro", header: "<table class=\"properties\"><tbody>"
    + property("date", "Date", "<time>@March 4, 2024 2:15 PM</time>")
    + property("checkbox", "Done", "<div class=\"checkbox checkbox-on\"></div>")
    + property("multi_select", "Tags", "<span class=\"selected-value\">first week</span>")
    + property("file", "Slides", "<a href=\"Intro%20\(intro)/slides.pdf\">slides.pdf</a>")
    + property("relation", "Course", "<a href=\"../../Course%20\(course).html\">Course</a>")
    + "</tbody></table>", body: "<p id=\"d1\" class=\"\">The first lecture.</p>")
private let lecturesCSV = "\u{FEFF}Name,Date,Done,Tags,Slides\nIntro,\"March 4, 2024 2:15 PM\",Yes,first week,slides.pdf\nRecap,\"March 11, 2024\",No,\"review, last week\",\n"
private let longPage = page(long, title: longTitle, body: "<p id=\"e1\" class=\"\">Long.</p>")
private let notesOnePage = page(notesOne, title: "Notes", body: "<p id=\"f1\" class=\"\">First notes.</p>")
private let notesTwoPage = page(notesTwo, title: "Notes", body: "<p id=\"f2\" class=\"\">Second notes.</p>")
private let weekNotesPage = page(weekNotes, title: "Notes", body: "<p id=\"f3\" class=\"\">Notes of the week.</p>")

private func madeUpExport() -> [Data] {
    let partOne = ZipBuilder(entries: [
        .stored("\(root)/Course \(course).html", text: coursePage),
        .stored("\(root)/Course \(course)/Week 1 \(week).html", text: weekPage),
        .stored("\(root)/Course \(course)/Lectures \(lectures).html", text: lecturesPage),
        .stored("\(root)/Course \(course)/Lectures \(lectures)_all.csv", text: lecturesCSV),
        .stored("\(root)/Course \(course)/Lectures \(lectures)/Intro \(intro).html", text: introPage),
        .stored("\(root)/Course \(course)/Lectures \(lectures)/Intro \(intro)/slides.pdf", text: "%PDF-1.4 slides"),
        .stored("\(root)/Course \(course)/diagram.png", Data((0..<200_000).map { UInt8($0 % 251) })),
        .stored("\(root)/../escape.html", text: "<html></html>"),
    ]).data
    let partTwo = ZipBuilder(entries: [
        .stored("\(root)/Course \(course)/Long title \(long).html", text: longPage),
        .stored("\(root)/Course \(course)/Notes \(notesOne).html", text: notesOnePage),
        .stored("\(root)/Course \(course)/Notes \(notesTwo).html", text: notesTwoPage),
        .stored("\(root)/Course \(course)/Week 1 \(week)/Notes \(weekNotes).html", text: weekNotesPage),
    ]).data
    // The download is a zip of the parts, the second part given beside it as a second file.
    let outer = ZipBuilder(entries: [.stored("\(root)-Part-1.zip", partOne)]).data
    return [outer, partTwo]
}

@Suite("A made-up Notion export")
struct NotionMadeUpExportTests {
    private func importMadeUpExport(into vault: TemporaryVault) async throws -> NotionHTMLImportResult {
        let sources: [any RandomAccessSource] = madeUpExport().map { MemoryRandomAccessSource(Array($0)) }
        let tree = try await ExportFileTree.reading(zipArchives: sources, named: ["Export.zip", "Export-Part-2.zip"],
                                                    temporaryStorage: MemoryTemporaryStorage())
        let options = NotionHTMLImportOptions(destinationFolder: VaultPath(components: ["School", "Notion"])!,
                                              exportName: "Export.zip", importDate: "2026-11-26", exportYear: 2024)
        return try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vault.folder),
                                                         options: options)
    }

    private func preparedVault() throws -> TemporaryVault {
        let vault = try TemporaryVault()
        let folder = vault.folder.appendingPathComponent("School/Notion")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: folder.appendingPathComponent("Course.md"))
        try FileManager.default.createDirectory(at: vault.folder.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try Data(#"{"types":{"Done":"text"},"other":1}"#.utf8).write(to: vault.folder.appendingPathComponent(".obsidian/types.json"))
        return vault
    }

    @Test("Pages land where the export nests them, a note the vault had is kept, and every link resolves")
    func pagesAndLinks() async throws {
        let vault = try preparedVault()
        defer { vault.remove() }
        let result = try await importMadeUpExport(into: vault)
        #expect(try vault.text("School/Notion/Course.md") == "kept")
        let course = try vault.text("School/Notion/Course 2.md")
        let longStem = VaultFileName.stem(forTitle: longTitle)
        #expect(longStem.utf8.count <= VaultFileName.maximumStemByteCount)
        #expect(course.hasPrefix("---\nicon: 🎓\n---\n"))
        #expect(course.contains("See [[Week 1]] and [[\(longStem)|the long one]]."))
        #expect(course.contains("> [!note]- Hidden part\n> Inside the toggle."))
        #expect(course.contains("> [!warning] ⚠️ Mind the **deadline**\n> It is on Friday."))
        #expect(course.contains("> [!multi-column]\n> > [!blank]\n> > Left\n>\n> > [!blank]\n> > Right\n"))
        #expect(course.contains("```cpp\nint main() { return 0; }\n```"))
        #expect(course.contains("Energy $E = mc^2$ costs \\$5 and \\#tag."))
        #expect(course.contains("![[diagram.png|400]]"))
        #expect(course.contains("![[Lectures.base]]"))
        // Two notes called Notes in two folders: each link names its path.
        #expect(course.contains("[[School/Notion/Course 2/Notes|Notes]]"))
        #expect(vault.exists("School/Notion/Course 2/Week 1/Notes.md"))
        #expect(vault.exists("School/Notion/Course 2/Notes.md"))
        #expect(vault.exists("School/Notion/Course 2/Notes 2.md"))
        #expect(vault.exists("School/Notion/Course 2/\(longStem).md"))
        #expect(try vault.text("School/Notion/Course 2/Week 1.md") == "Back to [[Course 2|the course]].\n")
        let findings = result.report.findings.map(\.message)
        #expect(findings.contains { $0.contains("../escape.html was not read") })
    }

    @Test("A database becomes a base over its rows' folder, its rows notes with typed properties, a row only its CSV holds a note too")
    func databaseAsBase() async throws {
        let vault = try preparedVault()
        defer { vault.remove() }
        let result = try await importMadeUpExport(into: vault)
        #expect(try vault.text("School/Notion/Course 2/Lectures.base") == """
            filters: file.folder == "School/Notion/Course 2/Lectures"
            properties:
              file.name:
                displayName: Name
              tags:
                displayName: Tags
            views:
              - type: table
                name: Table
                order:
                  - file.name
                  - Date
                  - Done
                  - tags
                  - Slides

            """)
        #expect(try vault.text("School/Notion/Course 2/Lectures/Intro.md") == """
            ---
            Date: 2024-03-04T14:15
            Done: true
            tags:
              - first-week
            Slides:
              - "[[slides.pdf]]"
            Course:
              - "[[Course 2|Course]]"
            ---
            The first lecture.

            """)
        #expect(try vault.text("School/Notion/Course 2/Lectures/Recap.md") == """
            ---
            Date: 2024-03-11
            Done: false
            tags:
              - review
              - last-week
            ---

            """)
        #expect(try vault.text("School/Notion/Course 2/Lectures/Intro/slides.pdf") == "%PDF-1.4 slides")
        #expect(result.propertyTypes["Date"] == .datetime)
        #expect(result.propertyTypes["tags"] == .tags)
        #expect(result.propertyTypes["Slides"] == .multitext)
        #expect(result.report.findings.contains { $0.message.contains("made from the database's CSV") })
    }

    @Test("Property types join the vault's, the types it had kept, and the large attachment is copied whole")
    func propertyTypesAndAttachments() async throws {
        let vault = try preparedVault()
        defer { vault.remove() }
        let result = try await importMadeUpExport(into: vault)
        let types = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.folder.appendingPathComponent(".obsidian/types.json"))) as? [String: Any]
        let assigned = types?["types"] as? [String: String]
        #expect(assigned?["Done"] == "text")
        #expect(assigned?["Date"] == "datetime")
        #expect(types?["other"] as? Int == 1)
        #expect(result.report.findings.contains { $0.message == "the property “Done” already has another type in this vault, which it keeps" })
        let diagram = try Data(contentsOf: vault.folder.appendingPathComponent("School/Notion/Course 2/diagram.png"))
        #expect(diagram == Data((0..<200_000).map { UInt8($0 % 251) }))
        let report = try vault.text("School/Notion/Notion import report.md")
        #expect(report.hasPrefix("# Notion import\n\nImported from Export.zip on 2026-11-26.\n\nWritten: 8 notes, 1 base, 2 attachments.\n"))
        #expect(report.contains("- [[School/Notion/Course 2/Lectures.base|Lectures.base]]"))
    }

    @Test("Importing the same export again writes beside the first import, never over it")
    func importingAgain() async throws {
        let vault = try preparedVault()
        defer { vault.remove() }
        _ = try await importMadeUpExport(into: vault)
        let first = try vault.text("School/Notion/Course 2.md")
        let second = try await importMadeUpExport(into: vault)
        #expect(try vault.text("School/Notion/Course 2.md") == first)
        #expect(vault.exists("School/Notion/Course 3.md"))
        #expect(second.reportPath.description == "School/Notion/Notion import report 2.md")
        #expect(try vault.text("School/Notion/Course 3/Week 1.md") == "Back to [[Course 3|the course]].\n")
    }
}
