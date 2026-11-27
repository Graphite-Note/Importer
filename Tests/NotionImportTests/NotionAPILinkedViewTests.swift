/**
 * File: NotionAPILinkedViewTests.swift
 * ------------------------------------
 * Layer: Tests
 * Description: A linked database, a view on a page of another database's data source, imported as views of that
 *              database's base and embedded where the page had it, and a database Notion refuses to give left out.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import ImporterCore
import ImporterFileSystem
import ImporterTestSupport
@testable import NotionImport
import Testing

@Suite("Notion's linked databases")
struct NotionAPILinkedViewTests {
    static let weekPage = "90000000-0000-4000-8000-000000000001"
    static let linked = "91000000-0000-4000-8000-000000000001"

    /// The courses and assignments of the rollup tests, and a page showing the assignments on a board of its own.
    static func workspace() -> FakeNotionWorkspace {
        var workspace = NotionAPIRollupTests.workspace()
        let source = NotionAPIRollupTests.tasksSource
        workspace.dataSourceOwners[source] = NotionAPIRollupTests.tasks
        workspace.pages[weekPage] = FakeNotionWorkspace.page(weekPage, title: "Week plan", parent: FakeNotionWorkspace.parent("workspace", nil))
        workspace.blocks[weekPage] = listAnswer([
            .object([("object", .string("block")), ("id", .string(linked)), ("type", .string("child_database")), ("has_children", .bool(false)),
                     ("child_database", .object([("title", .string("This week"))]))]),
        ])
        workspace.databases[linked] = .object([
            ("object", .string("database")), ("id", .string(linked)), ("parent", FakeNotionWorkspace.parent("page_id", weekPage)),
            ("title", .array([.object([("plain_text", .string("This week"))])])),
            ("data_sources", .array([.object([("id", .string(source)), ("name", .string("Assignments"))])])),
        ])
        workspace.views[linked] = [
            .object([("object", .string("view")), ("id", .string("92000000-0000-4000-8000-000000000001")), ("name", .string("Board")),
                     ("type", .string("board")), ("data_source_id", .string(source)),
                     ("configuration", .object([("group_by", .object([("property_name", .string("Done")), ("sort", .object([("type", .string("ascending"))]))]))]))]),
        ]
        return workspace
    }

    private func importWorkspace(_ workspace: FakeNotionWorkspace, into vault: TemporaryVault,
                                 answer: (@Sendable (NotionRequest) -> NotionResponse?)? = nil) async throws -> NotionAPIImportResult {
        let clock = VirtualClock()
        let transport = ScriptedTransport(clock: clock) { request, _ in answer?(request) ?? workspace.answer(request) }
        let options = NotionAPIImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, importDate: "2026-11-27")
        return try await NotionAPIImporter.importWorkspace(client: NotionAPIClient(transport: transport, clock: clock),
                                                           into: FolderImportDestination(vaultFolder: vault.folder), options: options)
    }

    @Test("A linked database becomes a view of the base of the database it shows, embedded where its page had it")
    func linkedView() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let result = try await importWorkspace(Self.workspace(), into: vault)
        #expect(result.stoppedBecause == nil)
        #expect(try vault.text("Notion/Week plan.md").contains("![[Assignments.base#Board (This week)]]"))
        #expect(!vault.exists("Notion/Week plan/This week.base"))
        let base = try vault.text("Notion/Assignments.base")
        #expect(base.contains("  - type: table\n    name: Table\n"))
        #expect(base.contains("  - type: kanban\n    name: Board (This week)\n"))
        #expect(vault.exists("Notion/Assignments/Homework 1.md"))
        #expect(result.report.findings.contains {
            $0.message == "the linked database “This week” is embedded where its page had it as this base, opening on its view “Board (This week)”"
        })
    }

    @Test("A database Notion refuses to give is left out and reported, and the rest is imported")
    func refusedDatabase() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let result = try await importWorkspace(Self.workspace(), into: vault) { request in
            request.url.hasSuffix("databases/\(Self.linked)")
                ? jsonResponse(400, #"{"object":"error","code":"validation_error","message":"Linked databases are not supported."}"#) : nil
        }
        #expect(result.stoppedBecause == nil)
        #expect(vault.exists("Notion/Assignments.base"))
        #expect(try vault.text("Notion/Week plan.md").contains("This week"))
        #expect(result.report.findings.contains { $0.message.hasPrefix("a database (\(Self.linked)) was not imported: ") })
    }
}
