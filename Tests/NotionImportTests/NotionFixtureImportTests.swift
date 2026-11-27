/**
 * File: NotionFixtureImportTests.swift
 * ------------------------------------
 * Layer: Tests
 * Description: Obsidian Importer's own Notion test material imported: the HTML export compared file by file with
 *              the vault expected here and line by line with the notes upstream expects (every difference listed and
 *              explained in Tests/Fixtures/Notion/Differences.md), its database row page, and its Markdown export,
 *              which is refused.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

import Foundation
import ImporterCore
import ImporterFileSystem
import ImporterTestSupport
@testable import NotionImport
import Testing

private let notionFixtures = fixturesFolder.appendingPathComponent("Notion")
private let expectedVault = notionFixtures.appendingPathComponent("expected-importer/notion-testspace")
private let upstreamExpected = notionFixtures.appendingPathComponent("expected/notion-testspace")
private let upstreamDifferences = notionFixtures.appendingPathComponent("expected-importer/upstream-differences")

private func importFixture(_ name: String, into vault: TemporaryVault) async throws -> NotionHTMLImportResult {
    let source = try FileRandomAccessSource(url: notionFixtures.appendingPathComponent(name))
    let tree = try await ExportFileTree.reading(zipArchives: [source], named: [name], temporaryStorage: MemoryTemporaryStorage())
    let options = NotionHTMLImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, exportName: name,
                                          importDate: "2026-11-26", exportYear: 2024)
    return try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vault.folder), options: options)
}

@Suite("Obsidian Importer's Notion test material")
struct NotionFixtureImportTests {
    @Test("The HTML export imports as the expected vault, file by file")
    func htmlExportMatchesTheExpectedVault() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let result = try await importFixture("notion-testspace.zip", into: vault)
        #expect(result.report.writtenCount(of: .note) == 4)
        #expect(result.report.writtenCount(of: .attachment) == 5)
        #expect(result.report.findings.isEmpty)
        #expect(result.reportPath.description == "Notion/Notion import report.md")

        let notes = vault.filePaths().filter { $0.hasSuffix(".md") }
        let attachments = vault.filePaths().filter { !$0.hasSuffix(".md") }
        #expect(attachments == [
            "Notion/Notion-Testspace/Attachment Tests/----.jpg",
            "Notion/Notion-Testspace/Attachment Tests/felis-catus.jpg",
            "Notion/Notion-Testspace/Attachment Tests/kocky-jsou-nejlepsi.jpg",
            "Notion/Notion-Testspace/Attachment Tests/name-with-percents-006300610074.jpg",
            "Notion/Notion-Testspace/Attachment Tests/кошки-самые-лучшие.jpg",
        ].sorted())
        // The five attachments are the same 20,395-byte picture, copied whole.
        for attachment in attachments {
            let bytes = try Data(contentsOf: vault.folder.appendingPathComponent(attachment))
            #expect(bytes.count == 20_395)
            #expect(CRC32.checksum(of: bytes) == CRC32.checksum(of: try Data(contentsOf: vault.folder.appendingPathComponent(attachments[0]))))
        }

        if isRecordingExpectedFiles {
            try? FileManager.default.removeItem(at: expectedVault)
            for note in notes {
                let target = expectedVault.appendingPathComponent(note)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try vault.text(note).write(to: target, atomically: true, encoding: .utf8)
            }
        }
        #expect(notes == relativeFilePaths(under: expectedVault))
        for note in notes {
            let expected = try String(contentsOf: expectedVault.appendingPathComponent(note), encoding: .utf8)
            #expect(try vault.text(note) == expected, "\(note) differs from the expected note")
        }
    }

    @Test("Each note differs from the note upstream expects only as Differences.md explains",
          arguments: ["Notion-Testspace", "Block Reference", "Formatting Tests", "Attachment Tests"])
    func notesDifferFromUpstreamOnlyAsExplained(note: String) async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        _ = try await importFixture("notion-testspace.zip", into: vault)
        let produced = try vault.text(note == "Notion-Testspace" ? "Notion/Notion-Testspace.md" : "Notion/Notion-Testspace/\(note).md")
        let upstream = try String(contentsOf: upstreamExpected.appendingPathComponent("\(note).md"), encoding: .utf8)
        let differences = lineDifferences(from: upstream, to: produced)
        let recorded = upstreamDifferences.appendingPathComponent("\(note).diff")
        if isRecordingExpectedFiles {
            try FileManager.default.createDirectory(at: upstreamDifferences, withIntermediateDirectories: true)
            try differences.write(to: recorded, atomically: true, encoding: .utf8)
        }
        #expect(differences == (try String(contentsOf: recorded, encoding: .utf8)))
    }

    @Test("Upstream's database row page gives the same properties, the number and dates typed")
    func databaseRow() throws {
        let html = try String(contentsOf: notionFixtures.appendingPathComponent("database-row.html"), encoding: .utf8)
        let page = NotionPageReader.read(html: html, exportPath: ["Espresso machine.html"], resolver: NoLinks(),
                                         dateParser: NotionDateParser(defaultYear: 2024))
        let produced = page.frontMatter.yaml + MarkdownWriter.markdown(for: page.blocks)
        let upstream = try String(contentsOf: notionFixtures.appendingPathComponent("expected/database-row.md"), encoding: .utf8)
        // Upstream's note ends without a line end, which the note written here has.
        #expect(produced == upstream + "\n")
        #expect(page.title == "Espresso machine")
        let types = Dictionary(uniqueKeysWithValues: page.propertyTypes.map { ($0.name, $0.type) })
        #expect(types["Price"] == .number)
        #expect(types["tags"] == .tags)
        #expect(types["Bought"] == .date)
        #expect(types["Serviced"] == .checkbox)
    }

    @Test("The Markdown & CSV export is refused with its reason, and nothing is written")
    func markdownExportIsRefused() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        await #expect(throws: NotionImportError.markdownExport) {
            _ = try await importFixture("Notion.Test.Export.zip", into: vault)
        }
        #expect(vault.filePaths().isEmpty)
        #expect(NotionImportError.markdownExport.description.contains("HTML"))
    }
}

/// A resolver for a page read on its own, which links to nothing.
struct NoLinks: NotionLinkResolving {
    func target(ofPage identifier: String) -> NotionLinkTarget? { nil }
    func attachmentTarget(atExportPath exportPath: [String]) -> String? { nil }
    func pageIdentifier(atExportPath exportPath: [String]) -> String? { nil }
    func headingText(inPage pageIdentifier: String, block blockIdentifier: String) -> String? { nil }
}
