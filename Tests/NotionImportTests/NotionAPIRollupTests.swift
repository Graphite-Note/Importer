/**
 * File: NotionAPIRollupTests.swift
 * --------------------------------
 * Layer: Tests
 * Description: Notion's rollups as formulas of the base: each function Bases can compute written over the notes the
 *              relation links to, and a whole import of two made-up related databases whose rollups the base computes,
 *              one of whose rows has a title a file name cannot hold.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

import ImporterCore
import ImporterFileSystem
import ImporterTestSupport
@testable import NotionImport
import Testing

@Suite("Notion's rollups")
struct NotionAPIRollupTests {
    static let courses = "70000000-0000-4000-8000-000000000001"
    static let coursesSource = "70000000-0000-4000-8000-000000000002"
    static let tasks = "80000000-0000-4000-8000-000000000001"
    static let tasksSource = "80000000-0000-4000-8000-000000000002"
    static let homework = "81000000-0000-4000-8000-000000000001"
    static let problemSet = "82000000-0000-4000-8000-000000000001"
    static let algebra = "71000000-0000-4000-8000-000000000001"

    @Test("Each rollup function Bases can compute becomes a formula over the related notes, the others are refused")
    func functions() {
        let notes = "list(note.Assignments).filter(value).map(value.asFile()).filter(value)"
        let points = notes + ".map(value.properties.Points)"
        let cases: [(NotionRollupConverter.Target, String, String)] = [
            (.title, "show_original", notes),
            (.property("Points"), "show_original", points),
            (.property("Points"), "count", notes + ".length"),
            (.property("Points"), "sum", points + ".sum()"),
            (.property("Points"), "average", points + ".mean()"),
            (.property("Points"), "range", "(" + points + ".max() - " + points + ".min())"),
            (.property("Points"), "not_empty", points + ".filter(!value.isEmpty()).length"),
            (.property("Due date"), "earliest_date", notes + #".map(value.properties["Due date"]).min()"#),
            (.property("Done"), "percent_checked",
             "if(" + notes + ".length == 0, 0, (" + notes + ".map(value.properties.Done).filter(value == true).length / " + notes + ".length * 100).round())"),
            (.title, "show_unique", notes + ".map(value.name).unique()"),
        ]
        for (target, function, formula) in cases {
            #expect(NotionRollupConverter.formula(relation: "Assignments", target: target, function: function) == formula)
        }
        #expect(NotionRollupConverter.formula(relation: "Assignments", target: .property("Done"), function: "count_per_group") == nil)
        #expect(NotionRollupConverter.formula(relation: "Assignments", target: .property("Due"), function: "date_range") == nil)
        #expect(NotionRollupConverter.formula(relation: "My tasks", target: .title, function: "count") == #"list(note["My tasks"]).filter(value).map(value.asFile()).filter(value).length"#)
    }

    private static func property(_ name: String, _ type: String, _ content: JSONValue = .object([])) -> (key: String, value: JSONValue) {
        (name, .object([("id", .string(name.lowercased())), ("type", .string(type)), (type, content)]))
    }

    private static func rollup(_ name: String, of target: String, _ function: String) -> (key: String, value: JSONValue) {
        property(name, "rollup", .object([("relation_property_name", .string("Assignments")), ("rollup_property_name", .string(target)),
                                          ("function", .string(function))]))
    }

    private static func database(_ identifier: String, _ title: String, source: String) -> JSONValue {
        .object([("object", .string("database")), ("id", .string(identifier)), ("parent", FakeNotionWorkspace.parent("workspace", nil)),
                 ("title", .array([.object([("plain_text", .string(title))])])),
                 ("data_sources", .array([.object([("id", .string(source)), ("name", .string(title))])]))])
    }

    private static func row(_ identifier: String, _ title: String, source: String, _ properties: [(key: String, value: JSONValue)]) -> JSONValue {
        let name: (key: String, value: JSONValue) = ("Name", .object([("id", .string("title")), ("type", .string("title")),
                                                                      ("title", .array([.object([("plain_text", .string(title))])]))]))
        return .object([("object", .string("page")), ("id", .string(identifier)), ("parent", FakeNotionWorkspace.parent("data_source_id", source)),
                        ("properties", .object([name] + properties))])
    }

    /// Courses with a relation to their assignments and rollups over it.
    static func workspace() -> FakeNotionWorkspace {
        var workspace = FakeNotionWorkspace()
        workspace.databases[courses] = database(courses, "Courses", source: coursesSource)
        workspace.databases[tasks] = database(tasks, "Assignments", source: tasksSource)
        workspace.dataSources[coursesSource] = .object([("object", .string("data_source")), ("id", .string(coursesSource)), ("properties", .object([
            property("Name", "title"),
            property("Assignments", "relation", .object([("data_source_id", .string(tasksSource)), ("type", .string("dual_property"))])),
            rollup("Points", of: "Points", "sum"),
            rollup("Done share", of: "Done", "percent_checked"),
            rollup("Titles", of: "Name", "show_original"),
            rollup("Per group", of: "Done", "count_per_group"),
        ]))])
        workspace.dataSources[tasksSource] = .object([("object", .string("data_source")), ("id", .string(tasksSource)), ("properties", .object([
            property("Name", "title"), property("Points", "number"), property("Done", "checkbox"),
        ]))])
        workspace.rows[coursesSource] = [row(algebra, "Algebra", source: coursesSource, [
            ("Assignments", .object([("id", .string("assignments")), ("type", .string("relation")), ("relation", .array([.object([("id", .string(homework))])]))])),
            ("Points", .object([("id", .string("points")), ("type", .string("rollup")),
                                ("rollup", .object([("type", .string("number")), ("number", .number("5")), ("function", .string("sum"))]))])),
            ("Per group", .object([("id", .string("per group")), ("type", .string("rollup")),
                                   ("rollup", .object([("type", .string("number")), ("number", .number("1")), ("function", .string("count_per_group"))]))])),
        ])]
        workspace.rows[tasksSource] = [row(homework, "Homework 1", source: tasksSource, [
            ("Points", .object([("id", .string("points")), ("type", .string("number")), ("number", .number("5"))])),
            ("Done", .object([("id", .string("done")), ("type", .string("checkbox")), ("checkbox", .bool(true))])),
        ]), row(problemSet, "Problem set 1: signals", source: tasksSource, [])]
        return workspace
    }

    @Test("Two related databases import with their rollups as formulas of the base, the notes holding only what Bases cannot compute")
    func wholeImport() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let clock = VirtualClock()
        let workspace = Self.workspace()
        let transport = ScriptedTransport(clock: clock) { request, _ in workspace.answer(request) }
        let options = NotionAPIImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, importDate: "2026-11-27")
        let result = try await NotionAPIImporter.importWorkspace(client: NotionAPIClient(transport: transport, clock: clock),
                                                                 into: FolderImportDestination(vaultFolder: vault.folder), options: options)
        #expect(result.stoppedBecause == nil)
        let base = try vault.text("Notion/Courses.base")
        let notes = "list(note.Assignments).filter(value).map(value.asFile()).filter(value)"
        #expect(base.contains("  Points: " + notes + ".map(value.properties.Points).sum()\n"))
        #expect(base.contains("  Titles: " + notes + "\n"))
        #expect(base.contains("Done share"))
        #expect(!base.contains("  Per group:"))
        #expect(base.contains("formula.Points"))
        let row = try vault.text("Notion/Courses/Algebra.md")
        #expect(row.contains("Assignments:\n  - \"[[Homework 1]]\""))
        #expect(!row.contains("Points:"))
        #expect(row.contains("Per group: 1"))
        #expect(result.propertyTypes["Per group"] == .number)
        #expect(!result.report.findings.contains { $0.message.hasPrefix("the property “Per group” is") })
        #expect(result.report.findings.contains { $0.message == "the rollup “Per group” uses Notion's count per group, which Bases has no counterpart for, so each note holds its value when imported" })
    }

    @Test("A row whose title a file name cannot hold keeps it, as its title and alias, and its base shows it")
    func wholeTitles() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let clock = VirtualClock()
        let workspace = Self.workspace()
        let transport = ScriptedTransport(clock: clock) { request, _ in workspace.answer(request) }
        let options = NotionAPIImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, importDate: "2026-11-28")
        _ = try await NotionAPIImporter.importWorkspace(client: NotionAPIClient(transport: transport, clock: clock),
                                                        into: FolderImportDestination(vaultFolder: vault.folder), options: options)
        let row = try vault.text("Notion/Assignments/Problem set 1 signals.md")
        #expect(row.contains("title: \"Problem set 1: signals\"\naliases:\n  - \"Problem set 1: signals\"\n"), "\(row)")
        #expect(!(try vault.text("Notion/Assignments/Homework 1.md")).contains("title:"))
        let base = try vault.text("Notion/Assignments.base")
        #expect(base.contains("  title: file.asLink(if(note.title, note.title, file.basename))\n"), "\(base)")
        #expect(base.contains("  formula.title:\n    displayName: Name\n"), "\(base)")
        #expect(!base.contains("      - file.name\n"), "\(base)")
        // The courses' rows are named by their titles: their base shows file names.
        #expect(!(try vault.text("Notion/Courses.base")).contains("note.title"))
    }
}
