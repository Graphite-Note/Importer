/**
 * File: NotionAPITests.swift
 * --------------------------
 * Layer: Tests
 * Description: Notion's API without a network: JSON, the client's rate and retries, pages and databases converted
 *              from Obsidian Importer's fixtures and compared with its expected notes, formulas, and whole imports of a
 *              made-up workspace, with a revoked token, an unshared page and a cancelled import.
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

/// Pages and databases resolved as a whole import would, for the conversion tests.
private struct FixtureResolver: NotionAPIPropertyResolving {
    var pages: [String: String] = [:]
    var databases: [String: String] = [:]
    var files: [String: String] = [:]
    var titles: [String: String] = [:]
    func target(ofPage identifier: String) -> String? { pages[NotionAPIPageReader.plainIdentifier(identifier)] }
    func target(ofDatabase identifier: String) -> String? { databases[NotionAPIPageReader.plainIdentifier(identifier)] }
    func attachmentTarget(forFile url: String) -> String? { files[url] }
    func title(ofPage identifier: String) -> String? { titles[NotionAPIPageReader.plainIdentifier(identifier)] }
}

/// The blocks of a fixture's page, with their children, as the import reads them.
private func fixtureBlocks(_ fixture: JSONValue, of identifier: String) -> [NotionAPIBlock] {
    let blocks = fixture["blocks"] ?? .null
    return (blocks[identifier]?["results"]?.elements ?? []).map { json in
        var block = NotionAPIBlock(json: json)
        if block.type == "transcription" || block.type == "meeting_notes" {
            for (title, member) in [("Summary", "summary_block_id"), ("Notes", "notes_block_id"), ("Transcript", "transcript_block_id")] {
                if let section = block.content["children"]?[member]?.string { block.sections.append((title, fixtureBlocks(fixture, of: section))) }
            }
        } else if block.hasChildren {
            block.children = fixtureBlocks(fixture, of: block.identifier)
        }
        return block
    }
}

@Suite("Notion's API")
struct NotionAPITests {
    // MARK: JSON

    @Test("JSON is read and written again with its order, escapes, surrogate pairs and numbers as written")
    func json() throws {
        let text = #"{"b":1.50,"a":[true,false,null,"x\"y\\z\né😀"],"c":{"d":-2e3}}"#
        let value = try JSONValue.parse(text)
        #expect(value["b"]?.numberText == "1.50")
        #expect(value["a"]?.elements[3].string == "x\"y\\z\né😀")
        #expect(value["c"]?["d"]?.numberText == "-2e3")
        #expect(value.members.map(\.key) == ["b", "a", "c"])
        #expect(try JSONValue.parse(value.text) == value)
        #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse("{\"a\":}") }
        #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse("[1,2") }
    }

    // MARK: The client

    @Test("Requests keep to three a second after a burst of ten, and each asks for the API version")
    func rate() async throws {
        let clock = VirtualClock()
        let transport = ScriptedTransport(clock: clock) { _, _ in jsonResponse(200, "{}") }
        let client = NotionAPIClient(transport: transport, clock: clock)
        for _ in 0..<16 { _ = try await client.get("users/me") }
        let times = await transport.requests.map(\.at)
        #expect(times.prefix(10).allSatisfy { $0 == 0 })
        // After the burst, a request every third of a second.
        #expect(times[10] >= 333 && times[15] >= 5 * 333)
        #expect(times[15] <= 2_100)
        let first = await transport.requests[0].request
        #expect(first.headers.contains(NotionHeader(name: "Notion-Version", value: "2025-09-03")))
        #expect(first.isNotionAPI)
    }

    @Test("A 429 waits as long as Retry-After says, a 5xx and a lost network wait longer each time, then the request goes through")
    func retries() async throws {
        let clock = VirtualClock()
        let transport = ScriptedTransport(clock: clock) { _, count in
            switch count {
            case 0: return jsonResponse(429, #"{"object":"error","code":"rate_limited","message":"slow down"}"#, headers: [NotionHeader(name: "Retry-After", value: "7")])
            case 1: return jsonResponse(502, #"{"message":"bad gateway"}"#)
            case 2: throw URLError(.notConnectedToInternet)
            case 3: return jsonResponse(503, #"{"message":"unavailable"}"#)
            default: return jsonResponse(200, #"{"ok":true}"#)
            }
        }
        let client = NotionAPIClient(transport: transport, clock: clock)
        let answer = try await client.get("pages/1")
        #expect(answer["ok"]?.bool == true)
        #expect(await clock.waits.filter { $0 >= 1_000 } == [7_000, 14_000, 28_000, 56_000])
        #expect(await client.retriedRequestCount == 4)
    }

    @Test("Notion busy for longer than the policy allows fails with unavailable, a 401 at once with unauthorized")
    func givingUp() async throws {
        let clock = VirtualClock()
        let busy = ScriptedTransport(clock: clock) { _, _ in jsonResponse(503, #"{"message":"down"}"#) }
        let client = NotionAPIClient(transport: busy, clock: clock, policy: NotionRequestPolicy(giveUpAfterMilliseconds: 120_000))
        await #expect(throws: NotionAPIError.unavailable("Notion answered 503")) { try await client.get("pages/1") }
        let revoked = ScriptedTransport(clock: clock) { _, _ in jsonResponse(401, #"{"object":"error","code":"unauthorized","message":"API token is invalid."}"#) }
        let second = NotionAPIClient(transport: revoked, clock: clock)
        await #expect(throws: NotionAPIError.unauthorized("API token is invalid.")) { try await second.get("pages/1") }
        #expect(await revoked.requests.count == 1)
    }

    @Test("A list is read page after page with its cursor, in the query for GET and in the body for POST")
    func pagination() async throws {
        let clock = VirtualClock()
        let transport = ScriptedTransport(clock: clock) { request, count in
            count == 0
                ? jsonResponse(200, #"{"results":[{"id":"a"}],"has_more":true,"next_cursor":"c 1"}"#)
                : jsonResponse(200, #"{"results":[{"id":"b"}],"has_more":false,"next_cursor":null}"#)
        }
        let client = NotionAPIClient(transport: transport, clock: clock)
        let results = try await client.allResults(get: "blocks/x/children")
        #expect(results.compactMap { $0["id"]?.string } == ["a", "b"])
        let urls = await transport.requests.map(\.request.url)
        #expect(urls[1] == "https://api.notion.com/v1/blocks/x/children?page_size=100&start_cursor=c%201")
    }

    @Test("A file is downloaded in ranges, never whole, and a server that ignores ranges gives it at once")
    func rangedDownload() async throws {
        let clock = VirtualClock()
        let file = (0..<25).map { UInt8($0) }
        let transport = ScriptedTransport(clock: clock) { request, _ in
            let range = request.headers.first { $0.name == "Range" }?.value ?? ""
            let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
            let start = bounds[0], end = min(bounds[1], file.count - 1)
            return NotionResponse(status: 206, headers: [NotionHeader(name: "Content-Range", value: "bytes \(start)-\(end)/\(file.count)")],
                                  body: Array(file[start...end]))
        }
        let client = NotionAPIClient(transport: transport, clock: clock)
        var pieces: [[UInt8]] = []
        try await client.download("https://files.example.com/big.bin", pieceSize: 10) { pieces.append($0) }
        #expect(pieces.map(\.count) == [10, 10, 5])
        #expect(pieces.flatMap { $0 } == file)
        #expect(await transport.requests.allSatisfy { !$0.request.isNotionAPI })
    }

    // MARK: Pages and databases from the fixtures

    @Test("The example page converts block by block as recorded, close to Obsidian Importer's note")
    func examplePage() throws {
        let fixture = try apiFixture("example-page.json")
        let read = NotionAPIPageReader.read(fixtureBlocks(fixture, of: fixture["pageId"]?.string ?? ""), resolver: FixtureResolver())
        let markdown = MarkdownWriter.markdown(for: read.blocks)
        try compareWithRecorded(markdown, "example-page.md")
        #expect(markdown.contains("# A heading\n\nPlain, **bold**, _italic_, ~~struck~~, <u>underlined</u>, `code`, ==highlighted== and a [link](https://example.com)."))
        #expect(markdown.contains("- [x] Done\n- [ ] Not done"))
        #expect(markdown.contains("> [!tip] 💡 Something to note."))
        #expect(markdown.contains("```javascript\nconst answer = 42;\nconsole.log(answer);\n```"))
        #expect(markdown.contains("> [!note]- More detail\n> Hidden until opened."))
        #expect(markdown.contains("$$\nE = mc^2\n$$"))
        #expect(markdown.contains("| Name | Value |\n| --- | --- |\n| Answer | 42 |"))
    }

    @Test("Toggle headings stay headings with their content after them, and meeting notes keep their sections")
    func togglesAndMeetings() throws {
        let toggles = try apiFixture("toggle-headings-page.json")
        let toggleMarkdown = MarkdownWriter.markdown(for: NotionAPIPageReader.read(fixtureBlocks(toggles, of: toggles["pageId"]?.string ?? ""),
                                                                                 resolver: FixtureResolver()).blocks)
        try compareWithRecorded(toggleMarkdown, "toggle-headings-page.md")
        let meeting = try apiFixture("meeting-notes-page.json")
        let meetingMarkdown = MarkdownWriter.markdown(for: NotionAPIPageReader.read(fixtureBlocks(meeting, of: meeting["pageId"]?.string ?? ""),
                                                                                  resolver: FixtureResolver()).blocks)
        try compareWithRecorded(meetingMarkdown, "meeting-notes-page.md")
        #expect(meetingMarkdown.hasPrefix("## Weekly sync\n\n### Summary\n\nThe team agreed to ship the importer fix this week."))
    }

    @Test("A database row's properties: numbers, a relation inside the import as a link, one outside as its title")
    func databaseRows() throws {
        let fixture = try apiFixture("example-database.json")
        var resolver = FixtureResolver()
        let rows = fixture["rows"]?.elements ?? []
        for row in rows {
            let title = NotionAPIPropertyReader.title(of: row["properties"] ?? .null)
            resolver.pages[NotionAPIPageReader.plainIdentifier(row["id"]?.string ?? "")] = "Notion/Movies/" + title + "|" + title
        }
        for (identifier, page) in fixture["relatedPages"]?.members ?? [] {
            resolver.titles[NotionAPIPageReader.plainIdentifier(identifier)] = NotionAPIPropertyReader.title(of: page["properties"] ?? .null)
        }
        var written: [String] = []
        for row in rows {
            var reader = NotionAPIPropertyReader(resolver: resolver)
            var frontMatter = FrontMatter()
            frontMatter.set("notion-id", to: .text(row["id"]?.string ?? ""))
            for property in reader.read(row["properties"] ?? .null) { frontMatter.set(property.name, to: property.value) }
            written.append(NotionAPIPropertyReader.title(of: row["properties"] ?? .null) + "\n" + frontMatter.yaml)
        }
        try compareWithRecorded(written.joined(separator: "\n"), "example-database.md")
    }

    @Test("The board fixture becomes a base with a table and four Kanban views, its formula computed by the base")
    func boardViews() throws {
        let fixture = try apiFixture("board-views.json")
        let database = JSONValue.object([("data_source_schema", fixture["properties"] ?? .null)])
        let formulas = NotionAPIImportRun.convertibleFormulas(of: database)
        #expect(formulas == ["State": #"if(note["Done"], "Closed", "Open")"#])
        let base = NotionAPIBaseWriter.base(for: database, schema: fixture["properties"] ?? .null, views: fixture["views"]?.elements ?? [],
                                            dataSource: fixture["dataSourceId"]?.string ?? "", rowsFolder: VaultPath(components: ["Notion", "Tasks"])!,
                                            formulas: formulas)
        try compareWithRecorded(base.file.yaml, "board-views.base")
        #expect(base.file.views.map(\.type) == ["table", "kanban", "kanban", "kanban", "kanban"])
        #expect(base.findings.map(\.message).contains("the view “Other source” shows another data source of the database and was left out"))
    }

    @Test("Notion formulas in Bases' language, and the functions Bases lacks refused by name")
    func formulas() throws {
        let cases: [(String, String)] = [
            (#"prop("Price") * prop("Quantity")"#, #"note["Price"] * note["Quantity"]"#),
            (#"if(prop("Done"), "✅", "⏳")"#, #"if(note["Done"], "✅", "⏳")"#),
            (#"prop("Done") ? 1 : 0"#, #"if(note["Done"], 1, 0)"#),
            (#"length(prop("Name"))"#, #"note["Name"].length"#),
            (#"prop("Name").length()"#, #"note["Name"].length"#),
            (#"lower(prop("Name")) + "!""#, #"note["Name"].lower() + "!""#),
            (#"dateAdd(prop("Due"), 3, "days")"#, #"note["Due"] + "3 days""#),
            (#"sum(1, 2, prop("Extra"))"#, #"[1, 2, note["Extra"]].flat().sum()"#),
            (#"prop("Score") > 10 and not empty(prop("Name"))"#, #"(note["Score"] > 10) && (!note["Name"].isEmpty())"#),
            (#"map(prop("Tags"), upper(current))"#, #"note["Tags"].map(value.upper())"#),
            (#"{{notion:block_property:abc:00000000-0000-0000-0000-000000000000:1}} + 1"#, #"note["Total"] + 1"#),
            (#"prop("Total") * 2"#, #"formula["Total"] * 2"#),
        ]
        for (index, (notion, bases)) in cases.enumerated() {
            let formulaNames: Set<String> = index == cases.count - 1 ? ["Total"] : []
            #expect(try NotionFormulaConverter.convert(notion, propertyNames: ["abc": "Total"], formulaNames: formulaNames) == bases)
        }
        #expect(throws: NotionFormulaConverter.Failure.unsupportedFunction("dateBetween")) {
            try NotionFormulaConverter.convert(#"dateBetween(now(), prop("Start"), "days")"#)
        }
        #expect(throws: NotionFormulaConverter.Failure.unsupportedFunction("pow")) { try NotionFormulaConverter.convert("2 ^ 3") }
        #expect(throws: NotionFormulaConverter.Failure.unreadable) { try NotionFormulaConverter.convert("if(") }
    }

    // MARK: Whole imports

    private func importWorkspace(_ workspace: FakeNotionWorkspace, into vault: TemporaryVault, roots: [String] = [],
                                 answer: (@Sendable (NotionRequest, Int) -> NotionResponse?)? = nil) async throws -> NotionAPIImportResult {
        let clock = VirtualClock()
        let transport = ScriptedTransport(clock: clock) { request, count in
            answer?(request, count) ?? workspace.answer(request)
        }
        let client = NotionAPIClient(transport: transport, clock: clock)
        let options = NotionAPIImportOptions(destinationFolder: VaultPath(components: ["Notion"])!, importDate: "2026-11-27", rootIdentifiers: roots)
        return try await NotionAPIImporter.importWorkspace(client: client, into: FolderImportDestination(vaultFolder: vault.folder), options: options)
    }

    @Test("A workspace imports as pages nested in folders, the database as a base with its rows, the picture downloaded, and the report")
    func wholeImport() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let result = try await importWorkspace(try FakeNotionWorkspace.make(), into: vault)
        #expect(result.stoppedBecause == nil)
        #expect(!result.wasCancelled)
        let example = try vault.text("Notion/Example page.md")
        #expect(example.hasPrefix("---\nnotion-id: \(FakeNotionWorkspace.examplePage)\nicon: 📘\n---\n# A heading"))
        #expect(example.contains("[[Toggle headings]]"))
        #expect(example.contains("![[Tasks.base]]"))
        #expect(vault.exists("Notion/Example page/Toggle headings.md"))
        let base = try vault.text("Notion/Example page/Tasks.base")
        #expect(base.hasPrefix("filters: file.folder == \"Notion/Example page/Tasks\"\nformulas:\n  State: "))
        let row = try vault.text("Notion/Example page/Tasks/Paint the fence.md")
        #expect(row.contains("Status: In progress\nPriority: High"))
        #expect(!row.contains("State"))
        #expect(try vault.text("Notion/Files.md") == "---\nnotion-id: \(FakeNotionWorkspace.filesPage)\n---\n![[Notion/Files/Diagram 1.png]]\n")
        #expect(try Data(contentsOf: vault.folder.appendingPathComponent("Notion/Files/Diagram 1.png")) == Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        #expect(vault.exists("Notion/Weekly meeting.md"))
        let types = try String(contentsOf: vault.folder.appendingPathComponent(".obsidian/types.json"), encoding: .utf8)
        #expect(types.contains("\"Done\" : \"checkbox\""))
        let report = try vault.text("Notion/Notion import report.md")
        #expect(report.hasPrefix("# Notion import\n\nImported from Notion's API on 2026-11-27.\n\nWritten: "))
    }

    @Test("Choosing one page imports it with what it holds and nothing else")
    func chosenPage() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        _ = try await importWorkspace(try FakeNotionWorkspace.make(), into: vault, roots: [FakeNotionWorkspace.filesPage])
        #expect(vault.exists("Notion/Files.md"))
        #expect(!vault.exists("Notion/Example page.md"))
        #expect(!vault.exists("Notion/Weekly meeting.md"))
    }

    @Test("A token revoked during the import stops it with what was written and a report that says why")
    func revokedToken() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let result = try await importWorkspace(try FakeNotionWorkspace.make(), into: vault) { request, _ in
            request.url.contains("blocks/\(FakeNotionWorkspace.meetingPage)/children")
                ? jsonResponse(401, #"{"object":"error","code":"unauthorized","message":"API token is invalid."}"#) : nil
        }
        #expect(result.stoppedBecause?.hasPrefix("Notion refused the token (API token is invalid.)") == true)
        #expect(vault.exists("Notion/Example page.md"))
        #expect(!vault.exists("Notion/Weekly meeting.md"))
        #expect(try vault.text("Notion/Notion import report.md").contains("the import ended early: Notion refused the token"))
    }

    @Test("A page unshared during the import is reported and the others are imported")
    func unsharedPage() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let result = try await importWorkspace(try FakeNotionWorkspace.make(), into: vault) { request, _ in
            request.url.contains("blocks/\(FakeNotionWorkspace.filesPage)/children")
                ? jsonResponse(404, #"{"object":"error","code":"object_not_found","message":"Could not find block."}"#) : nil
        }
        #expect(result.stoppedBecause == nil)
        #expect(!vault.exists("Notion/Files.md"))
        #expect(vault.exists("Notion/Weekly meeting.md"))
        #expect(result.report.findings.contains { $0.message.hasPrefix("“Files” was not imported: Notion did not give this page") })
    }

    @Test("Notion answering 429 and 503 and a lost network on the way still give the whole import")
    func busyNotion() async throws {
        let vault = try TemporaryVault()
        defer { vault.remove() }
        let result = try await importWorkspace(try FakeNotionWorkspace.make(), into: vault) { _, count in
            switch count {
            case 3: return jsonResponse(429, #"{"message":"slow down"}"#, headers: [NotionHeader(name: "Retry-After", value: "2")])
            case 6: return jsonResponse(503, #"{"message":"unavailable"}"#)
            default: return nil
            }
        }
        #expect(result.stoppedBecause == nil)
        #expect(vault.exists("Notion/Example page/Tasks/Paint the fence.md"))
        #expect(vault.exists("Notion/Files/Diagram 1.png"))
    }

    // MARK: Recorded output

    /// Compares `text` with `Tests/Fixtures/NotionAPI/expected-importer/<name>`, or writes it there when
    /// `IMPORTER_RECORD_EXPECTED` is set.
    private func compareWithRecorded(_ text: String, _ name: String) throws {
        let url = fixturesFolder.appendingPathComponent("NotionAPI/expected-importer/\(name)")
        if isRecordingExpectedFiles {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return
        }
        let recorded = try String(contentsOf: url, encoding: .utf8)
        #expect(text == recorded, "\(name) differs from the recorded output")
    }
}
