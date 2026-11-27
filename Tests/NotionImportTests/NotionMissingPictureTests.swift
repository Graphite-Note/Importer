/**
 * File: NotionMissingPictureTests.swift
 * -------------------------------------
 * Layer: Tests
 * Description: Pictures a page shows from files its export does not hold: kept as their names and reported, never
 *              written as embeds or images that show nothing.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import Foundation
import ImporterCore
import ImporterTestSupport
@testable import NotionImport
import Testing

@Suite("Pictures missing from the export")
struct NotionMissingPictureTests {
    private static let identifier = "9999999999999999aaaaaaaaaaaaaaaa"

    @Test("A picture whose file the export lacks is kept as its name, reported, and a picture beside it still embeds")
    func missingPictureKeptAsItsName() async throws {
        let hyphenated = NotionPageReader.hyphenatedIdentifier(Self.identifier)!
        let body = """
            <figure id="a1" class="image"><a href="Shapes%20\(Self.identifier)/untitled"><img style="width:288px" src="Shapes%20\(Self.identifier)/untitled"/></a></figure>\
            <figure id="a2" class="image"><a href="Shapes%20\(Self.identifier)/Untitled.png"><img src="Shapes%20\(Self.identifier)/Untitled.png"/></a></figure>\
            <p id="a3" class="">Inline <img src="Shapes%20\(Self.identifier)/gone%20too.png"/> and from the web <img src="https://example.com/sun.png"/>.</p>
            """
        let html = """
            <html><head><meta charset="utf-8"/><title>Shapes</title></head><body><article id="\(hyphenated)" class="page sans">\
            <header><h1 class="page-title">Shapes</h1></header><div class="page-body">\(body)</div></article></body></html>
            """
        let export = ZipBuilder(entries: [
            .stored("Export/Shapes \(Self.identifier).html", text: html),
            .stored("Export/Shapes \(Self.identifier)/Untitled.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ]).data
        let tree = try await ExportFileTree.reading(zipArchives: [DataRandomAccessSource(export)], named: ["Export.zip"],
                                                    temporaryStorage: MemoryTemporaryStorage())
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let options = NotionHTMLImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, exportName: "Export.zip",
                                              importDate: "2026-11-27", exportYear: 2026)
        let result = try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vault.folder), options: options)
        let note = try vault.text("Notion/Shapes.md")
        #expect(note == "untitled\n\n![[Untitled.png]]\n\nInline gone too.png and from the web ![](https://example.com/sun.png).\n")
        let findings = result.report.findings.map(\.message)
        #expect(findings.contains("a picture, untitled, which the export does not hold, was kept as its name"))
        #expect(findings.contains("a picture, gone too.png, which the export does not hold, was kept as its name"))
    }
}
