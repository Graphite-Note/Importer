/**
 * File: NotionFidelityTests.swift
 * -------------------------------
 * Layer: Tests
 * Description: A made-up export in Notion's HTML since 2025 holding what a comparison of real exports with their notes
 *              found shown otherwise than in Notion: a view of a database on another page, styles whose Markdown
 *              delimiters cannot close where they end, headings with math and colors that links name, bold over code,
 *              line breaks before a change of style, a numbered list starting at another number than 1 inside an
 *              item, links to pages apart, links whose text is a space or nothing, a style over a link's whole text,
 *              Notion's own icon pictures on callouts, a property without a name, a table whose title column is not
 *              first, the default highlight and a toggle heading with math.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 28/11/2026
 */

import Foundation
import ImporterCore
import ImporterFileSystem
import ImporterTestSupport
@testable import NotionImport
import Testing

private let board = "f1000000000000000000000000000001"
private let projects = "f2000000000000000000000000000002"
private let brakes = "f3000000000000000000000000000003"
private let steering = "f4000000000000000000000000000004"
private let notes = "f5000000000000000000000000000005"
private let stepHeading = "e1000000-0000-4000-8000-000000000001"
private let toggleHeading = "e2000000-0000-4000-8000-000000000002"
private let space = "d0000000-0000-4000-8000-000000000000"

private func hyphenated(_ digits: String) -> String { NotionPageReader.hyphenatedIdentifier(digits)! }

private func page(_ identifier: String, title: String, header: String = "", body: String) -> String {
    """
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><title>\(title)</title></head><body>\
    <article id="\(hyphenated(identifier))" class="page sans"><header>\
    <h1 class="page-title" dir="auto">\(title)</h1><p class="page-description" dir="auto"></p>\(header)</header>\
    <div class="page-body">\(body)</div></article></body></html>
    """
}

private func pageLink(_ identifier: String, _ path: String, _ title: String) -> String {
    "<figure id=\"l\(identifier.prefix(4))\" class=\"link-to-page\"><a href=\"\(path)\" data-notion-page-id=\"\(hyphenated(identifier))\" "
        + "data-notion-space-id=\"\(space)\">\(title)</a></figure>"
}

private func header(_ name: String, icon: String) -> String {
    "<th><span class=\"icon property-icon\"><img src=\"https://app.notion.com/icons/\(icon)_gray.svg\" "
        + "style=\"width:14px;height:14px;display:block\"/></span>\(name)</th>"
}

/// The view on the board: the due date first, then the name, and only the row Brakes.
private let linkedView = """
    <div id="\(hyphenated("f6000000000000000000000000000006"))" class="collection-content" dir="ltr"><h4 class="collection-title">Open projects</h4>\
    <div class="collection-content-wrapper"><table class="collection-content"><colgroup><col style="width:25%"/><col style="width:75%"/></colgroup>\
    <thead><tr>\(header("Due", icon: "calendar"))\(header("Name", icon: "font"))</tr></thead><tbody>\
    <tr id="\(hyphenated(brakes))"><td class="cell-d"><time>March 4, 2026</time></td><td class="cell-title">\
    <a href="Board/Projects/Brakes%20\(brakes).html" data-notion-page-id="\(hyphenated(brakes))">Brakes</a></td></tr>\
    </tbody></table></div></div>
    """

private let boardBody = """
    <nav id="t1" class="block-color-gray table_of_contents"><div class="table_of_contents-item table_of_contents-indent-0">\
    <a class="table_of_contents-link" href="#\(stepHeading)">Step 2: azimuth α</a></div></nav>\
    \(linkedView)\
    <p id="p1" class="" dir="auto"><strong>Impact :</strong>Interruption, and <strong>So:</strong>\u{200B}next.</p>\
    <h2 id="\(stepHeading)" class="" dir="auto">Step 2: <strong>azimuth</strong> <span data-notion-inline-equation="\\alpha" \
    class="notion-text-equation-token" contenteditable="false"><span class="katex">α</span></span></h2>\
    <p id="p2" class="" dir="auto"><code>Model: </code><code><strong>Ellipse 2</strong></code> and <code>ssh -T </code><code>git@example.com</code>.</p>\
    <p id="p3" class="" dir="auto">Plies <br/><strong>UD 10</strong><br/><strong>UD 45</strong></p>\
    <ol id="o1" type="1" class="numbered-list" start="1" dir="auto"><li>Open the page<ol type="a" id="o2" class="numbered-list" start="3" dir="auto">\
    <li>the third one</li></ol></li></ol>\
    \(pageLink(projects, "Board/Projects%20\(projects).html", "Projects"))<p id="p4" class="" dir="auto"></p>\
    \(pageLink(notes, "Board/Notes%20\(notes).html", "Notes"))\
    <p id="p5" class="" dir="auto">A<a href="https://example.com/space"> </a>gap, nothing<a href="https://example.com/none"></a>here, \
    <a href="Board/Projects/Brakes%20\(brakes).html"><em>Brakes </em></a>next.</p>\
    <aside class="block-color-gray_background callout" data-notion-callout="" data-notion-callout-icon="/icons/exclamation-mark-double_red.svg" \
    data-notion-callout-background="gray_background" dir="ltr"><div><img class="icon notion-static-icon" \
    src="https://app.notion.com/icons/exclamation-mark-double_red.svg"/></div><div style="width:100%">Mind the date.</div></aside>\
    <p id="p6" class="" dir="auto"><mark class="highlight-default_background" data-notion-highlight="default_background">Plain</mark> text.</p>\
    <details open="" class="" dir="auto"><summary style="font-weight:600;font-size:1.5em;line-height:1.3;margin:0">\
    <h2 id="\(toggleHeading)" style="display:inline-block">Distributions of <span data-notion-inline-equation="v_x" \
    class="notion-text-equation-token" contenteditable="false"><span class="katex">vx</span></span></h2></summary>\
    <div class="indented"><p id="p7" class="" dir="auto">Inside.</p></div></details>
    """

/// The database's own table: the name first.
private let projectsTable = """
    <div class="collection-content-wrapper"><table class="collection-content"><colgroup><col style="width:70%"/><col style="width:30%"/></colgroup>\
    <thead><tr>\(header("Name", icon: "font"))\(header("Due", icon: "calendar"))</tr></thead><tbody>\
    <tr id="\(hyphenated(brakes))"><td class="cell-title"><a href="Projects/Brakes%20\(brakes).html" data-notion-page-id="\(hyphenated(brakes))">Brakes</a></td>\
    <td class="cell-d"><time>March 4, 2026</time></td></tr>\
    <tr id="\(hyphenated(steering))"><td class="cell-title"><a href="Projects/Steering%20\(steering).html" data-notion-page-id="\(hyphenated(steering))">Steering</a></td>\
    <td class="cell-d"></td></tr></tbody></table></div>
    """

private let unnamedProperty = """
    <table class="properties"><tbody><tr class="property-row property-row-person"><th><span class="icon property-icon">\
    <img src="https://app.notion.com/icons/user-circle-filled_gray.svg" style="width:14px;height:14px;display:block"/></span></th>\
    <td><span class="user">Ada Lovelace</span></td></tr></tbody></table>
    """

private func fidelityExport() -> Data {
    ZipBuilder(entries: [
        .stored("Export/Board \(board).html", text: page(board, title: "Board", body: boardBody)),
        .stored("Export/Board/Projects \(projects).html", text: page(projects, title: "Projects", body: projectsTable)),
        .stored("Export/Board/Projects \(projects).csv", text: "\u{FEFF}Name,Due\nBrakes,\"March 4, 2026\"\nSteering,\n"),
        .stored("Export/Board/Projects/Brakes \(brakes).html", text: page(brakes, title: "Brakes", header: unnamedProperty,
                                                                          body: "<p id=\"b1\" class=\"\" dir=\"auto\">A row.</p>")),
        .stored("Export/Board/Projects/Steering \(steering).html", text: page(steering, title: "Steering",
                                                                             body: "<p id=\"s1\" class=\"\" dir=\"auto\">Another.</p>")),
        .stored("Export/Board/Notes \(notes).html", text: page(notes, title: "Notes", body: "<p id=\"n1\" class=\"\" dir=\"auto\">Notes.</p>")),
    ]).data
}

@Suite("Notion's pages shown as Notion shows them")
struct NotionFidelityTests {
    private func importExport() async throws -> (TemporaryVault, NotionHTMLImportResult) {
        let tree = try await ExportFileTree.reading(zipArchives: [MemoryRandomAccessSource(Array(fidelityExport()))],
                                                    named: ["Export.zip"], temporaryStorage: MemoryTemporaryStorage())
        let vault = try TemporaryVault()
        let options = NotionHTMLImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, exportName: "Export.zip",
                                              importDate: "2026-11-28", exportYear: 2026)
        let result = try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vault.folder), options: options)
        return (vault, result)
    }

    @Test("A view of a database on another page is a base in the page: its columns in order, at their widths, its rows")
    func linkedView() async throws {
        let (vault, result) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Board.md")
        #expect(note.contains("""
            ```base
            filters: file.folder == "Notion/Board/Projects"
            properties:
              file.name:
                displayName: Name
            views:
              - type: table
                name: Open projects
                filters:
                  or:
                    - file.path == "Notion/Board/Projects/Brakes.md"
                order:
                  - Due
                  - file.name
                columnSize:
                  note.Due: 180
                  file.name: 540
            ```
            """), "\(note)")
        #expect(result.report.findings.contains { $0.message.hasPrefix("the view “Open projects” of a database shows the rows it showed") })
        // The database's own base keeps the name first, as its table shows it.
        let base = try vault.text("Notion/Board/Projects.base")
        #expect(base.contains("    order:\n      - file.name\n      - Due\n"), "\(base)")
    }

    @Test("Styles that cannot close in place are HTML elements, headings are named as written, code keeps its bold")
    func styles() async throws {
        let (vault, _) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Board.md")
        #expect(note.contains("<strong>Impact :</strong>Interruption, and <strong>So:</strong>\u{200B}next."), "\(note)")
        // A heading is bold already: its bold is left out, and the contents link names its math as the heading writes it.
        #expect(note.contains("\n## Step 2: azimuth $\\alpha$\n"), "\(note)")
        #expect(note.hasPrefix("- [[#Step 2: azimuth $\\alpha$|Step 2: azimuth α]]\n"), "\(note)")
        #expect(note.contains("`Model: `**`Ellipse 2`** and `ssh -T git@example.com`."), "\(note)")
        #expect(note.contains("Plain text."), "\(note)")
        #expect(note.contains("\n## Distributions of $v_x$\n\nInside.\n"), "\(note)")
    }

    @Test("Line breaks before a style, a list starting at 3, links apart, blank links and a styled link keep their look")
    func layout() async throws {
        let (vault, _) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Board.md")
        #expect(note.contains("Plies  \n**UD 10**  \n**UD 45**\n"), "\(note)")
        #expect(note.contains("1. Open the page\n\n    3. the third one\n"), "\(note)")
        // An empty paragraph between two links to pages is a gap: the links stay two paragraphs.
        #expect(note.contains("[[Projects.base|Projects]]\n\n[[Notes]]\n"), "\(note)")
        #expect(note.contains("A[ ](https://example.com/space)gap, nothing[](https://example.com/none)here, _[[Brakes]]_ next."), "\(note)")
        #expect(note.contains("> [!important] ‼️ Mind the date.\n"), "\(note)")
    }

    @Test("A property without a name is named Untitled, once in the report")
    func unnamedProperty() async throws {
        let (vault, result) = try await importExport()
        defer { vault.remove() }
        let row = try vault.text("Notion/Board/Projects/Brakes.md")
        #expect(row.hasPrefix("---\nUntitled: Ada Lovelace\n---\n"), "\(row)")
        #expect(result.report.findings.filter { $0.message == NotionPropertyReader.unnamedPropertyMessage }.count == 1)
    }
}
