/**
 * File: NotionReadmeDemoTests.swift
 * ---------------------------------
 * Layer: Tests
 * Description: The workspace made in Notion for the README's pictures (`Tests/Fixtures/Notion/signals-and-systems.zip`,
 *              fictional content), imported whole: its page's icon, cover, callout and columns, the database and the
 *              linked view of it, and rows whose titles hold a colon a file name cannot, which keep their whole titles.
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

private let demoExport = fixturesFolder.appendingPathComponent("Notion/signals-and-systems.zip")

@Suite("The README's demo workspace")
struct NotionReadmeDemoTests {
    private func importDemo() async throws -> (TemporaryVault, NotionHTMLImportResult) {
        let tree = try await ExportFileTree.reading(zipArchives: [try FileRandomAccessSource(url: demoExport)],
                                                    named: ["signals-and-systems.zip"], temporaryStorage: MemoryTemporaryStorage())
        let vault = try TemporaryVault()
        let options = NotionHTMLImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, exportName: "signals-and-systems.zip",
                                              importDate: "2026-11-28", exportYear: 2026)
        let result = try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vault.folder), options: options)
        return (vault, result)
    }

    @Test("The course page keeps its icon, cover, callout and columns, and only the linked view is reported")
    func coursePage() async throws {
        let (vault, result) = try await importDemo()
        defer { vault.remove() }
        let note = try vault.text("Notion/Signals & Systems.md")
        #expect(note.hasPrefix("---\nicon: 📡\nbanner: https://app.notion.com/images/page-cover/gradients_10.jpg\n---\n"), "\(note)")
        #expect(note.contains("\n> [!tip] 💡\n> Office hours on Tuesdays"), "\(note)")
        #expect(note.contains("\n> [!multi-column]\n"), "\(note)")
        #expect(result.report.findings.map(\.message) == [
            "the view “Assignments” of a database shows the rows it showed in Notion: the export does not give the view's filter",
        ])
    }

    @Test("A row whose title a file name cannot hold keeps it: its title and alias, and the name its base shows")
    func wholeTitles() async throws {
        let (vault, _) = try await importDemo()
        defer { vault.remove() }
        let row = try vault.text("Notion/Signals & Systems/Assignments/Problem set 1 signals.md")
        #expect(row.contains("\ntitle: \"Problem set 1: signals\"\naliases:\n  - \"Problem set 1: signals\"\n---\n"), "\(row)")
        // A row named by its title stays as it was.
        let clean = try vault.text("Notion/Signals & Systems/Assignments/Audio filter project.md")
        #expect(!clean.contains("title:") && !clean.contains("aliases:"), "\(clean)")
        let base = try vault.text("Notion/Signals & Systems/Assignments.base")
        #expect(base.contains("formulas:\n  title: file.asLink(if(note.title, note.title, file.basename))\nproperties:\n  formula.title:\n    displayName: Name\n"), "\(base)")
        // The export names no view: the one view is the database's title, as Notion shows it above the table.
        #expect(base.contains("    name: Assignments\n"), "\(base)")
        #expect(base.contains("    order:\n      - formula.title\n      - Due\n"), "\(base)")
        // The linked view on Sampling shows its two rows by their titles too.
        let sampling = try vault.text("Notion/Signals & Systems/Sampling.md")
        #expect(sampling.contains("```base\nfilters: file.folder == \"Notion/Signals & Systems/Assignments\"\nformulas:\n  title: file.asLink(if(note.title, note.title, file.basename))\n"), "\(sampling)")
        #expect(sampling.contains("        - file.path == \"Notion/Signals & Systems/Assignments/Problem set 1 signals.md\"\n"), "\(sampling)")
    }
}
