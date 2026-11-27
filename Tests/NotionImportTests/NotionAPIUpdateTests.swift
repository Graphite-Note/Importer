/**
 * File: NotionAPIUpdateTests.swift
 * --------------------------------
 * Layer: Tests
 * Description: Importing the made-up workspace again over its earlier import: notes matched by notion-id, a note
 *              changed in Notion replaced, a note changed in the vault kept, a moved note found where it went, new
 *              pages added, and no folder, note or attachment written twice.
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

@Suite("Importing again through Notion's API")
struct NotionAPIUpdateTests {
    static let newPage = "a0000000-0000-4000-8000-000000000001"

    private func run(_ workspace: FakeNotionWorkspace, into vault: TemporaryVault, updating: Bool) async throws -> NotionAPIImportResult {
        let clock = VirtualClock()
        let transport = ScriptedTransport(clock: clock) { request, _ in workspace.answer(request) }
        let client = NotionAPIClient(transport: transport, clock: clock)
        let options = NotionAPIImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, importDate: "2026-11-27")
        let destination = FolderImportDestination(vaultFolder: vault.folder)
        return updating
            ? try await NotionAPIImporter.updateImport(client: client, in: destination, options: options)
            : try await NotionAPIImporter.importWorkspace(client: client, into: destination, options: options)
    }

    private func files(in vault: TemporaryVault) throws -> Set<String> {
        Set(try FileManager.default.subpathsOfDirectory(atPath: vault.folder.appendingPathComponent("Notion").path))
    }

    @Test("Importing again replaces what changed in Notion, keeps what changed in the vault, and adds the new pages beside")
    func importAgain() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        var workspace = try FakeNotionWorkspace.make()
        _ = try await run(workspace, into: vault, updating: false)
        #expect(vault.exists("Notion/.notion-import.json"))
        let before = try files(in: vault)

        // In Notion: the example page's icon changes and a page is added. In the vault: a note is edited, one moved.
        workspace.pages[FakeNotionWorkspace.examplePage] = FakeNotionWorkspace.page(FakeNotionWorkspace.examplePage, title: "Example page",
                                                                                   parent: FakeNotionWorkspace.parent("workspace", nil), icon: "📗")
        workspace.pages[Self.newPage] = FakeNotionWorkspace.page(Self.newPage, title: "New page", parent: FakeNotionWorkspace.parent("workspace", nil))
        let meeting = vault.folder.appendingPathComponent("Notion/Weekly meeting.md")
        let edited = try String(contentsOf: meeting, encoding: .utf8) + "\nMy own line.\n"
        try edited.write(to: meeting, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: vault.folder.appendingPathComponent("Notion/Example page/Toggle headings.md"),
                                         to: vault.folder.appendingPathComponent("Notion/Toggle headings.md"))

        let result = try await run(workspace, into: vault, updating: true)
        #expect(result.stoppedBecause == nil)
        #expect(try vault.text("Notion/Example page.md").contains("icon: 📗"))
        #expect(try vault.text("Notion/Weekly meeting.md") == edited)
        #expect(vault.exists("Notion/New page.md"))
        #expect(vault.exists("Notion/Toggle headings.md"))
        #expect(!vault.exists("Notion/Example page/Toggle headings.md"))
        // Nothing written twice: the only new files are the new page, the second report and the moved note.
        let added = try files(in: vault).subtracting(before)
        #expect(added == ["New page.md", "Notion import report 2.md", "Toggle headings.md"])
        #expect(result.report.findings.contains {
            $0.path?.description == "Notion/Weekly meeting.md" && $0.message.hasPrefix("“Weekly meeting” changed in the vault since the earlier import")
        })
        #expect(result.report.source.contains("It updates the earlier import in this folder: 1 replaced, "))
        #expect(result.report.source.hasSuffix(" 1 kept as changed in the vault."))
        #expect(unchangedCount(result) > 3)
        #expect(result.report.written.map(\.path.description).contains("Notion/Example page.md"))
        #expect(!result.report.written.map(\.path.description).contains("Notion/Files/Diagram 1.png"))

        // A third import leaves the kept note alone again and changes nothing else.
        let third = try await run(workspace, into: vault, updating: true)
        #expect(try vault.text("Notion/Weekly meeting.md") == edited)
        #expect(third.report.source.contains(" 0 replaced, "))
        #expect(third.report.source.hasSuffix(" 1 kept as changed in the vault."))
    }

    /// How many notes and bases the update found unchanged, read back from its own words.
    private func unchangedCount(_ result: NotionAPIImportResult) -> Int {
        let words = result.report.source.pieces(separatedBy: " ")
        guard let index = words.firstIndex(of: "unchanged,"), index > 0 else { return -1 }
        return Int(words[index - 1]) ?? -1
    }

    @Test("A folder with no earlier import imports everything as new, and says so")
    func nothingEarlier() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let result = try await run(try FakeNotionWorkspace.make(), into: vault, updating: true)
        #expect(vault.exists("Notion/Example page.md"))
        #expect(result.report.findings.contains { $0.message.hasPrefix("no earlier import of this workspace was found in this folder") })
    }

    @Test("The record of an import reads back, and a note's notion-id is found in its front matter")
    func record() throws {
        var record = NotionAPIImportRecord()
        record.entries["abc"] = NotionAPIImportRecord.Entry(path: VaultPath(components: ["Notion", "A.md"])!, fingerprint: ContentFingerprint.of(Array("x".utf8)))
        record.entries["def"] = NotionAPIImportRecord.Entry(path: VaultPath(components: ["Notion", "B.base"])!, fingerprint: nil)
        #expect(NotionAPIImportRecord(try JSONValue.parse(record.json.text)) == record)
        #expect(ContentFingerprint.of([]) == "cbf29ce484222325")
        #expect(ContentFingerprint.of(Array("a".utf8)) == "af63dc4c8601ec8c")
        #expect(NotionAPIImportRecord.notionIdentifier(inNote: "---\nicon: 📘\nnotion-id: \"1234\"\n---\nText") == "1234")
        #expect(NotionAPIImportRecord.notionIdentifier(inNote: "Text\nnotion-id: 1234\n") == nil)
    }
}
