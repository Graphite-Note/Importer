/**
 * File: NotionAPITestSupport.swift
 * --------------------------------
 * Layer: Tests
 * Description: Notion's API answered without a network for the tests: a clock whose waits pass at once, a transport
 *              scripted request by request, and a made-up workspace served from Obsidian Importer's API fixtures.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import Foundation
import ImporterCore
import ImporterTestSupport
@testable import NotionImport

/// A clock whose waits pass at once and move its time on, recording each wait.
actor VirtualClock: NotionClock {
    private(set) var now: Int64 = 0
    private(set) var waits: [Int64] = []

    func nowMilliseconds() -> Int64 { now }

    func sleep(milliseconds: Int64) throws {
        try Task.checkCancellation()
        waits.append(milliseconds)
        now += milliseconds
    }
}

/// A transport that answers each request with `answer`, given the request and how many came before it, and records
/// every request with the time it was sent at.
actor ScriptedTransport: NotionTransport {
    private let clock: VirtualClock
    private let answer: @Sendable (NotionRequest, Int) async throws -> NotionResponse
    private(set) var requests: [(request: NotionRequest, at: Int64)] = []

    init(clock: VirtualClock, answer: @escaping @Sendable (NotionRequest, Int) async throws -> NotionResponse) {
        self.clock = clock
        self.answer = answer
    }

    func send(_ request: NotionRequest) async throws -> NotionResponse {
        let count = requests.count
        requests.append((request, await clock.nowMilliseconds()))
        return try await answer(request, count)
    }
}

/// An answer with a JSON body.
func jsonResponse(_ status: Int, _ json: String, headers: [NotionHeader] = []) -> NotionResponse {
    NotionResponse(status: status, headers: headers, body: Array(json.utf8))
}

/// A fixture of `Tests/Fixtures/NotionAPI`, read as JSON.
func apiFixture(_ name: String) throws -> JSONValue {
    try JSONValue.parse(Array(try Data(contentsOf: fixturesFolder.appendingPathComponent("NotionAPI/\(name)"))))
}

/// A list answer as Notion gives one, all at once.
func listAnswer(_ results: [JSONValue]) -> JSONValue {
    .object([("object", .string("list")), ("results", .array(results)), ("has_more", .bool(false)), ("next_cursor", .null)])
}

/// A made-up workspace shared with an integration, served as Notion's API serves it, from Obsidian Importer's
/// fixtures: a page with every block type and, under it, a page of toggle headings and the Tasks database of the board
/// fixture with its rows and views; a page of AI meeting notes; a page showing a picture Notion holds.
struct FakeNotionWorkspace: Sendable {
    static let examplePage = "10000000-0000-4000-8000-000000000001"
    static let togglePage = "50000000-0000-4000-8000-000000000001"
    static let meetingPage = "30000000-0000-4000-8000-000000000001"
    static let filesPage = "60000000-0000-4000-8000-000000000001"
    static let pictureAddress = "https://files.example.com/abc/Diagram%201.png?X-Amz-Signature=1"

    var pages: [String: JSONValue] = [:]
    var blocks: [String: JSONValue] = [:]
    var databases: [String: JSONValue] = [:]
    var dataSources: [String: JSONValue] = [:]
    var rows: [String: [JSONValue]] = [:]
    var views: [String: [JSONValue]] = [:]
    var files: [String: [UInt8]] = [:]

    static func page(_ identifier: String, title: String, parent: JSONValue, icon: String? = nil) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [("object", .string("page")), ("id", .string(identifier)), ("parent", parent)]
        if let icon { members.append(("icon", .object([("type", .string("emoji")), ("emoji", .string(icon))]))) }
        members.append(("properties", .object([("title", .object([("id", .string("title")), ("type", .string("title")),
                                                                 ("title", .array([.object([("plain_text", .string(title))])]))]))])))
        return .object(members)
    }

    static func parent(_ type: String, _ identifier: String?) -> JSONValue {
        guard let identifier else { return .object([("type", .string("workspace")), ("workspace", .bool(true))]) }
        return .object([("type", .string(type)), (type, .string(identifier))])
    }

    static func make() throws -> FakeNotionWorkspace {
        var workspace = FakeNotionWorkspace()
        let example = try apiFixture("example-page.json")
        let toggles = try apiFixture("toggle-headings-page.json")
        let meeting = try apiFixture("meeting-notes-page.json")
        let board = try apiFixture("board-views.json")
        for fixture in [example, toggles, meeting] {
            for (identifier, value) in fixture["blocks"]?.members ?? [] { workspace.blocks[identifier] = value }
        }
        let toggleIdentifier = toggles["pageId"]?.string ?? togglePage
        // The example page holds the toggle page and the database, as child page and child database blocks.
        if case .object(var members)? = workspace.blocks[examplePage], case .array(var results)? = workspace.blocks[examplePage]?["results"] {
            results.append(.object([("object", .string("block")), ("id", .string(toggleIdentifier)), ("type", .string("child_page")),
                                    ("has_children", .bool(true)), ("child_page", .object([("title", .string("Toggle headings"))]))]))
            results.append(.object([("object", .string("block")), ("id", .string(board["databaseId"]?.string ?? "")), ("type", .string("child_database")),
                                    ("has_children", .bool(false)), ("child_database", .object([("title", .string("Tasks"))]))]))
            members = members.map { $0.key == "results" ? ("results", .array(results)) : $0 }
            workspace.blocks[examplePage] = .object(members)
        }
        workspace.pages[examplePage] = page(examplePage, title: "Example page", parent: parent("workspace", nil), icon: "📘")
        workspace.pages[toggleIdentifier] = page(toggleIdentifier, title: "Toggle headings", parent: parent("page_id", examplePage))
        workspace.pages[meetingPage] = page(meetingPage, title: "Weekly meeting", parent: parent("workspace", nil))
        workspace.pages[filesPage] = page(filesPage, title: "Files", parent: parent("workspace", nil))
        workspace.blocks[filesPage] = listAnswer([
            .object([("object", .string("block")), ("id", .string("61")), ("type", .string("image")), ("has_children", .bool(false)),
                     ("image", .object([("type", .string("file")), ("file", .object([("url", .string(pictureAddress))])),
                                        ("caption", .array([]))]))]),
        ])
        workspace.files[pictureAddress] = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]

        let database = board["databaseId"]?.string ?? ""
        let source = board["dataSourceId"]?.string ?? ""
        workspace.databases[database] = .object([
            ("object", .string("database")), ("id", .string(database)), ("parent", parent("page_id", examplePage)),
            ("title", .array([.object([("plain_text", .string(board["title"]?.string ?? "Tasks"))])])),
            ("data_sources", .array([.object([("id", .string(source)), ("name", .string("Tasks"))])])),
        ])
        workspace.dataSources[source] = .object([("object", .string("data_source")), ("id", .string(source)), ("properties", board["properties"] ?? .null)])
        workspace.rows[source] = (board["rows"]?.elements ?? []).map { row in
            guard case .object(let members) = row else { return row }
            return .object(members + [("parent", parent("data_source_id", source))])
        }
        workspace.views[database] = board["views"]?.elements ?? []
        return workspace
    }

    /// The search's results: every page, row and data source.
    var searchResults: [JSONValue] {
        var results = pages.keys.sorted().compactMap { pages[$0] }
        for (source, sourceRows) in rows.sorted(by: { $0.key < $1.key }) {
            results += sourceRows
            let database = databases.first { $0.value["data_sources"]?.elements.contains { $0["id"]?.string == source } == true }?.key ?? ""
            results.append(.object([("object", .string("data_source")), ("id", .string(source)), ("parent", FakeNotionWorkspace.parent("database_id", database))]))
        }
        return results
    }

    /// Notion's answer to `request`.
    func answer(_ request: NotionRequest) -> NotionResponse {
        if let file = files[request.url] { return NotionResponse(status: 200, body: file) }
        guard request.url.hasPrefix(NotionAPIClient.baseAddress) else { return jsonResponse(404, #"{"object":"error","code":"object_not_found","message":"no file"}"#) }
        let address = String(request.url.dropFirst(NotionAPIClient.baseAddress.count))
        let path = address.split(separator: "?").first.map(String.init) ?? address
        let parts = path.split(separator: "/").map(String.init)
        let notFound = jsonResponse(404, #"{"object":"error","code":"object_not_found","message":"Could not find it."}"#)
        switch (request.method, parts.count, parts.first ?? "") {
        case ("POST", 1, "search"): return jsonResponse(200, listAnswer(searchResults).text)
        case ("GET", 2, "pages"): return pages[parts[1]].map { jsonResponse(200, $0.text) } ?? notFound
        case ("GET", 2, "databases"): return databases[parts[1]].map { jsonResponse(200, $0.text) } ?? notFound
        case ("GET", 2, "data_sources"): return dataSources[parts[1]].map { jsonResponse(200, $0.text) } ?? notFound
        case ("POST", 3, "data_sources"): return jsonResponse(200, listAnswer(rows[parts[1]] ?? []).text)
        case ("GET", 3, "blocks"): return jsonResponse(200, (blocks[parts[1]] ?? listAnswer([])).text)
        case ("GET", 1, "views"):
            let database = address.split(separator: "=").last.map(String.init) ?? ""
            let listed = (views[database] ?? []).map { view in JSONValue.object([("object", .string("view")), ("id", view["id"] ?? .null)]) }
            return jsonResponse(200, listAnswer(listed).text)
        case ("GET", 2, "views"):
            for list in views.values { if let view = list.first(where: { $0["id"]?.string == parts[1] }) { return jsonResponse(200, view.text) } }
            return notFound
        default: return notFound
        }
    }
}
