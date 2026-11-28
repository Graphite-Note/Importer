/**
 * File: NotionExport2026Tests.swift
 * ---------------------------------
 * Layer: Tests
 * Description: A made-up export in the HTML Notion writes since 2025: emoji icons in `data-emoji`, callouts as
 *              `aside`, a database's table inside `collection-content-wrapper` with its column widths, its rows in a
 *              folder named without an identifier and its CSV beside its page, columns with their ratios, colored
 *              text and headings, pictures with their width, links to pages one after the other, phone numbers and
 *              e-mail addresses as Notion links them, and a zip a page holds.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 28/11/2026
 */

import Foundation
import ImporterCore
import ImporterFileSystem
import ImporterTestSupport
@testable import NotionImport
import Testing

private let home = "c1000000000000000000000000000001"
private let projects = "c2000000000000000000000000000002"
private let brakes = "c3000000000000000000000000000003"
private let steering = "c4000000000000000000000000000004"
private let logins = "c5000000000000000000000000000005"
private let alpha = "c6000000000000000000000000000006"
private let space = "d0000000-0000-4000-8000-000000000000"

private func hyphenated(_ digits: String) -> String { NotionPageReader.hyphenatedIdentifier(digits)! }

/// A page as Notion's export writes one since 2025: the icon in `data-emoji`, also named by the article.
private func page(_ identifier: String, title: String, emoji: String, header: String = "", body: String) -> String {
    """
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><title>\(title)</title></head><body>\
    <article id="\(hyphenated(identifier))" class="page sans" data-notion-page-icon="\(emoji)"><header>\
    <div class="page-header-icon undefined"><span class="icon" data-emoji="\(emoji)"></span></div>\
    <h1 class="page-title" dir="auto">\(title)</h1><p class="page-description" dir="auto"></p>\(header)</header>\
    <div class="page-body">\(body)</div></article></body></html>
    """
}

private func pageLink(_ identifier: String, _ path: String, _ title: String, emoji: String) -> String {
    "<figure id=\"l\(identifier.prefix(4))\" class=\"link-to-page\"><a href=\"\(path)\" data-notion-page-id=\"\(hyphenated(identifier))\" "
        + "data-notion-space-id=\"\(space)\"><span class=\"icon\" data-emoji=\"\(emoji)\"></span>\(title)</a></figure>"
}

private let homeBody = """
    <aside class="block-color-red_background callout" data-notion-callout="" data-notion-callout-icon="🌐" \
    data-notion-callout-background="red_background" style="white-space:pre-wrap;display:flex" id="e1" dir="ltr">\
    <div style="font-size:1.5em"><span class="icon" data-emoji="🌐"></span></div><div style="width:100%">\
    <strong>Go see the videos</strong><br/><a href="https://example.com/videos">https://example.com/videos</a></div></aside>\
    <div id="e2" class="column-list" data-notion-column-list="" dir="auto">\
    <div id="e3" style="width:25%" class="column" data-notion-column-ratio="0.25" dir="auto">\
    \(pageLink(projects, "Home/Projects%20\(projects).html", "Projects", emoji: "🏎️"))\
    \(pageLink(brakes, "Home/Projects/Brakes%20\(brakes).html", "Brakes", emoji: "🛑"))</div>\
    <div id="e4" style="width:50%" class="column" data-notion-column-ratio="0.5" dir="auto">\
    <h2 id="e5" class="block-color-red" dir="auto">Admin</h2><p id="e6" class="" dir="auto">A <mark class="highlight-blue" \
    data-notion-highlight="blue">blue</mark> word and a <mark class="highlight-yellow_background" \
    data-notion-highlight="yellow_background">marked</mark> one.</p></div>\
    <div id="e7" style="width:25%" class="column" data-notion-column-ratio="0.25" dir="auto"><p id="e8" class="" dir="auto">Right.</p></div></div>\
    <figure id="e9" class="image" data-notion-image="Home/car.png" dir="ltr"><a href="Home/car.png"><img style="width:720px" src="Home/car.png"/></a></figure>\
    <figure id="f1" class="equation" data-notion-equation="E = mc^2" dir="auto"><div class="equation-container"><span class="katex-display">\
    <span class="katex"><span class="katex-html" aria-hidden="true">E</span></span></span></div></figure>\
    <p id="f2" class="" dir="auto">So <span data-notion-inline-equation="h=1-q" class="notion-text-equation-token" contenteditable="false">\
    <span class="katex"><span class="katex-html" aria-hidden="true">h</span></span></span> holds.</p>\
    <div id="\(hyphenated(logins))" class="collection-content" dir="ltr"><h4 class="collection-title">Logins</h4>\
    <div class="collection-content-wrapper"><table class="collection-content"><colgroup><col style="width:60%"/><col style="width:40%"/></colgroup>\
    <thead><tr><th><span class="icon property-icon"><img src="https://app.notion.com/icons/font_gray.svg" style="width:14px;height:14px;display:block"/></span>Name</th>\
    <th><span class="icon property-icon"><img src="https://app.notion.com/icons/hashtag_gray.svg" style="width:14px;height:14px;display:block"/></span>Fee</th></tr></thead>\
    <tbody><tr id="\(hyphenated(alpha))"><td class="cell-title"><a href="Home/Logins/Alpha%20\(alpha).html">Alpha</a></td><td class="cell-f">CHF 9.90</td></tr></tbody>\
    </table></div></div>
    """

private let projectsTable = """
    <div class="collection-content-wrapper"><table class="collection-content"><colgroup><col style="width:50%"/><col style="width:30%"/>\
    <col style="width:20%"/></colgroup><thead><tr>\
    <th><span class="icon property-icon"><img src="https://app.notion.com/icons/font_gray.svg" style="width:14px;height:14px;display:block"/></span>Name</th>\
    <th><span class="icon property-icon"><img src="https://app.notion.com/icons/phone-call_gray.svg" style="width:14px;height:14px;display:block"/></span>Phone</th>\
    <th><span class="icon property-icon"><img src="https://app.notion.com/icons/calendar_gray.svg" style="width:14px;height:14px;display:block"/></span>Due</th>\
    </tr></thead><tbody>\
    <tr id="\(hyphenated(brakes))"><td class="cell-title"><a href="Projects/Brakes%20\(brakes).html" data-notion-page-id="\(hyphenated(brakes))">Brakes</a></td>\
    <td class="cell-p"><a href="+41 79 000 00 00" class="phone-value">+41 79 000 00 00</a></td><td class="cell-d"><time>March 4, 2026</time></td></tr>\
    <tr id="\(hyphenated(steering))"><td class="cell-title"><a href="Projects/Steering%20\(steering).html" data-notion-page-id="\(hyphenated(steering))">Steering</a></td>\
    <td class="cell-p"></td><td class="cell-d"></td></tr>\
    </tbody></table></div>
    """

private func row(_ identifier: String, _ title: String, phone: String?, email: String?) -> String {
    var properties = ""
    if let phone {
        properties += "<tr class=\"property-row property-row-phone_number\"><th>Phone</th><td><a href=\"\(phone)\" class=\"phone-value\">\(phone)</a></td></tr>"
    }
    if let email {
        properties += "<tr class=\"property-row property-row-email\"><th>Mail</th><td><a href=\"\(email)\" class=\"email-value\">\(email)</a></td></tr>"
    }
    let header = properties.isEmpty ? "" : "<table class=\"properties\"><tbody>\(properties)</tbody></table>"
    let body = phone.map { "<p id=\"r1\" class=\"\">Call <a href=\"\($0)\">the lead</a>.</p>" } ?? "<p id=\"r2\" class=\"\">A row.</p>"
    return page(identifier, title: title, emoji: "🛑", header: header, body: body)
}

private func export2026() -> Data {
    ZipBuilder(entries: [
        .stored("Export/Home \(home).html", text: page(home, title: "Home", emoji: "🏢", body: homeBody)),
        .stored("Export/Home/car.png", Data([0x89, 0x50, 0x4E, 0x47])),
        // An inline database since 2025: no page of its own, its CSV beside the page showing it, its rows in its folder.
        .stored("Export/Home/Logins \(logins).csv", text: "\u{FEFF}Name,Fee\nAlpha,CHF 9.90\nBeta,CHF 12.00\n"),
        .stored("Export/Home/Logins/Alpha \(alpha).html", text: page(alpha, title: "Alpha", emoji: "🔑", header: """
            <table class="properties"><tbody><tr class="property-row property-row-number"><th>Fee</th><td>CHF 9.90</td></tr>\
            <tr class="property-row property-row-date"><th>Since</th><td><time datetime="2026-05-03">03/05/2026</time></td></tr></tbody></table>
            """, body: "<p id=\"a1\" class=\"\">A login.</p>")),
        .stored("Export/Home/Projects \(projects).html", text: page(projects, title: "Projects", emoji: "🏎️", body: projectsTable)),
        .stored("Export/Home/Projects \(projects).csv", text: "\u{FEFF}Name,Phone,Due\nBrakes,+41 79 000 00 00,\"March 4, 2026\"\nSteering,,\n"),
        .stored("Export/Home/Projects/Brakes \(brakes).html", text: row(brakes, "Brakes", phone: "+41 79 000 00 00", email: "lead@example.com")),
        .stored("Export/Home/Projects/Steering \(steering).html", text: row(steering, "Steering", phone: nil, email: nil)),
        // A zip a page holds is a file of the page: copied as it is, never opened.
        .stored("Export/Home/Projects/Brakes/STEP-FILES.zip", ZipBuilder(entries: [.stored("part.step", text: "ISO-10303-21;")]).data),
    ]).data
}

@Suite("Notion's export since 2025")
struct NotionExport2026Tests {
    private func importExport() async throws -> (TemporaryVault, NotionHTMLImportResult) {
        let tree = try await ExportFileTree.reading(zipArchives: [MemoryRandomAccessSource(Array(export2026()))],
                                                    named: ["Export.zip"], temporaryStorage: MemoryTemporaryStorage())
        let vault = try TemporaryVault()
        let options = NotionHTMLImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, exportName: "Export.zip",
                                              importDate: "2026-11-28", exportYear: 2026)
        let result = try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vault.folder), options: options)
        return (vault, result)
    }

    @Test("Icons, callouts, columns, colors and pictures are kept as Notion draws them")
    func pageLook() async throws {
        let (vault, _) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Home.md")
        #expect(note.hasPrefix("---\nicon: 🏢\n---\n"), "\(note)")
        // After `<br>` an address is no autolink, so it is written between `<` and `>`.
        #expect(note.contains("> [!danger] 🌐 **Go see the videos**<br><https://example.com/videos>\n"), "\(note)")
        #expect(note.contains("> [!multi-column]\n> > [!blank]\n> > [[Projects]]  \n> > [[Brakes]]\n>\n> > [!blank|wide-2]\n"), "\(note)")
        // Text colors in the Colors plugin's syntax, which Graphite reads and writes, the yellow background a highlight.
        #expect(note.contains("> > ## ~={#e05a52}Admin=~\n"), "\(note)")
        #expect(note.contains("> > A ~={#3e89c9}blue=~ word and a ==marked== one.\n"), "\(note)")
        #expect(note.contains(">\n> > [!blank]\n> > Right.\n\n![[car.png|720]]\n"), "\(note)")
    }

    @Test("An inline database without a page of its own is a base over its rows, the rows its CSV adds made once")
    func inlineDatabase() async throws {
        let (vault, _) = try await importExport()
        defer { vault.remove() }
        let note = try vault.text("Notion/Home.md")
        #expect(note.contains("$$\nE = mc^2\n$$\n\nSo $h=1-q$ holds.\n\n![[Logins.base]]\n"), "\(note)")
        let base = try vault.text("Notion/Home/Logins.base")
        #expect(base.hasPrefix("filters: file.folder == \"Notion/Home/Logins\"\n"), "\(base)")
        #expect(base.contains("    columnSize:\n      file.name: 432\n      note.Fee: 288\n"), "\(base)")
        let alphaNote = try vault.text("Notion/Home/Logins/Alpha.md")
        #expect(alphaNote.hasPrefix("---\nFee: 9.9\nSince: 2026-05-03\nicon: 🔑\n---\n"), "\(alphaNote)")
        #expect(try vault.text("Notion/Home/Logins/Beta.md") == "---\nFee: 12\n---\n")
        #expect(!vault.exists("Notion/Home/Logins/Alpha 2.md"))
    }

    @Test("A database is a base over its rows' folder, with its columns' widths, its rows typed")
    func database() async throws {
        let (vault, _) = try await importExport()
        defer { vault.remove() }
        // The database's page has its own icon, so it is a note embedding the base, and keeps the icon.
        #expect(try vault.text("Notion/Home/Projects.md") == "---\nicon: 🏎️\n---\n![[Projects.base]]\n")
        let base = try vault.text("Notion/Home/Projects.base")
        #expect(base.hasPrefix("filters: file.folder == \"Notion/Home/Projects\"\n"), "\(base)")
        #expect(base.contains("    columnSize:\n      file.name: 360\n      note.Phone: 216\n      note.Due: 144\n"), "\(base)")
        let brakesNote = try vault.text("Notion/Home/Projects/Brakes.md")
        #expect(brakesNote.hasPrefix("---\nPhone: +41 79 000 00 00\nMail: lead@example.com\nicon: 🛑\n---\n"), "\(brakesNote)")
        #expect(brakesNote.contains("Call [the lead](tel:+41790000000)."), "\(brakesNote)")
    }

    @Test("A zip a page holds is copied whole, and phone numbers are no missing pages")
    func attachmentsAndReport() async throws {
        let (vault, result) = try await importExport()
        defer { vault.remove() }
        #expect(vault.exists("Notion/Home/Projects/Brakes/STEP-FILES.zip"))
        #expect(!vault.exists("Notion/Home/Projects/Brakes/part.step"))
        let messages = result.report.findings.map(\.message)
        #expect(!messages.contains { $0.contains("does not hold") }, "\(messages)")
    }
}
