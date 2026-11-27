/**
 * File: NotionAPIImporter.swift
 * -----------------------------
 * Layer: Notion
 * Description: Imports the pages and databases shared with a Notion integration through Notion's API: pages as notes
 *              nested as in Notion, databases as bases with their views and formulas, rows as notes with typed
 *              properties, files downloaded while their page is written, and the import report.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

import ImporterCore

/// How an import through Notion's API runs.
public struct NotionAPIImportOptions: Sendable {
    /// The vault folder the import writes in, made when missing.
    public var destinationFolder: VaultPath
    /// The import's day (`2026-11-27`), for the report.
    public var importDate: String
    /// The pages and databases to import, with everything inside them, by identifier. Empty: everything shared with
    /// the integration.
    public var rootIdentifiers: [String]
    public var reportName: String
    /// Called after each page or database is written, with how many are done of how many.
    public var progress: (@Sendable (_ done: Int, _ total: Int) -> Void)?

    public init(destinationFolder: VaultPath, importDate: String, rootIdentifiers: [String] = [], reportName: String = "Notion import report",
                progress: (@Sendable (Int, Int) -> Void)? = nil) {
        self.destinationFolder = destinationFolder
        self.importDate = importDate
        self.rootIdentifiers = rootIdentifiers
        self.reportName = reportName
        self.progress = progress
    }
}

/// What an import through the API did.
public struct NotionAPIImportResult: Sendable {
    public var report: ImportReport
    public var reportPath: VaultPath
    public var propertyTypes: [String: PropertyType]
    public var wasCancelled: Bool
    /// Why the import stopped before its end other than by cancelling (a revoked token, Notion unreachable).
    public var stoppedBecause: String?
}

/// Imports through Notion's API.
public enum NotionAPIImporter {
    public static func importWorkspace(client: NotionAPIClient, into destination: any ImportDestination,
                                       options: NotionAPIImportOptions) async throws -> NotionAPIImportResult {
        var run = NotionAPIImportRun(client: client, destination: destination, options: options)
        return try await run.run()
    }

    /// Imports the workspace again into the folder of an earlier import, `options.destinationFolder`: each page and
    /// database goes where the earlier import put it, matched by its `notion-id`, and replaces it only when nobody
    /// changed it since. A note changed in the vault is kept and reported. New pages and databases are added beside,
    /// attachments already there are kept.
    public static func updateImport(client: NotionAPIClient, in destination: any UpdatingImportDestination,
                                    options: NotionAPIImportOptions) async throws -> NotionAPIImportResult {
        var run = NotionAPIImportRun(client: client, destination: destination, options: options)
        run.updater = destination
        return try await run.run()
    }
}

/// A page or database of the import, as discovery found it.
struct NotionAPIItem {
    enum Kind { case page, database }
    var identifier: String
    var kind: Kind
    var title: String
    /// The page or database holding it, `nil` at the top. A row's parent is its database.
    var parent: String?
    var json: JSONValue
    /// The vault path of its note or base, and of the folder of what it holds.
    var path = VaultPath.vaultFolder
    var folder = VaultPath.vaultFolder
}

/// A linked database: a database whose data source is another database's, shown in the vault as views of that
/// database's base.
struct NotionAPILinkedDatabase {
    /// The key of the database whose data source it shows.
    var owner: String
    var title: String
    /// Its views, renamed for the owner's base.
    var views: [JSONValue]
    /// The view its embeds open on, `nil` for the base's first.
    var embeddedView: String?
}

/// One import through the API, from discovery to the report.
struct NotionAPIImportRun: NotionAPIPropertyResolving {
    let client: NotionAPIClient
    let destination: any ImportDestination
    let options: NotionAPIImportOptions
    var report: ImportReport
    var items: [String: NotionAPIItem] = [:]
    var order: [String] = []
    var linkTargets: [String: String] = [:]
    /// Data source identifiers to the database holding them.
    var databaseOfDataSource: [String: String] = [:]
    var fileTargets: [String: String] = [:]
    var outsideTitles: [String: String] = [:]
    var propertyTypes: [String: PropertyType] = [:]
    var folderNames: [VaultPath: VaultFolderNames] = [:]
    var rootFolder: VaultPath
    /// The properties of data sources read for rollups, by identifier, `nil` for one the integration cannot read.
    var dataSourceProperties: [String: JSONValue?] = [:]
    /// Linked databases by key, which have no base of their own.
    var linkedDatabases: [String: NotionAPILinkedDatabase] = [:]
    /// The names given to linked databases' views, lowercased.
    var linkedViewNames: Set<String> = []
    /// The databases whose base is written, by key.
    var writtenBases: Set<String> = []
    /// The destination when the import updates an earlier one.
    var updater: (any UpdatingImportDestination)?
    /// The earlier import's notes and bases, by key, with the fingerprint of what it wrote when known.
    var earlier: [String: NotionAPIImportRecord.Entry] = [:]
    /// What this import leaves, for the next one.
    var record = NotionAPIImportRecord()
    /// Notes and bases an update left as they were, replaced, and kept because they changed in the vault.
    var updateCounts = (unchanged: 0, replaced: 0, kept: 0)

    init(client: NotionAPIClient, destination: any ImportDestination, options: NotionAPIImportOptions) {
        self.client = client
        self.destination = destination
        self.options = options
        rootFolder = options.destinationFolder
        report = ImportReport(title: "Notion import", source: "Imported from Notion's API on \(options.importDate).")
    }

    static func key(_ identifier: String) -> String { NotionAPIPageReader.plainIdentifier(identifier) }

    // MARK: NotionAPIPropertyResolving

    func target(ofPage identifier: String) -> String? {
        let key = NotionAPIImportRun.key(identifier)
        guard items[key]?.kind == .page else { return nil }
        return linkTargets[key]
    }

    func target(ofDatabase identifier: String) -> String? {
        let key = NotionAPIImportRun.key(identifier)
        if let linked = linkedDatabases[key], let target = linkTargets[linked.owner] {
            return linked.embeddedView.map { target + "#" + $0 } ?? target
        }
        if let database = databaseOfDataSource[key] { return linkTargets[database] }
        guard items[key]?.kind == .database else { return nil }
        return linkTargets[key]
    }

    func attachmentTarget(forFile url: String) -> String? { fileTargets[url] }

    func title(ofPage identifier: String) -> String? { outsideTitles[NotionAPIImportRun.key(identifier)] }

    // MARK: The run

    mutating func run() async throws -> NotionAPIImportResult {
        var stoppedBecause: String?
        // Nothing is written before discovery and planning end: an error there means the import cannot start.
        try await discover()
        try await readEarlierImport()
        try await plan()
        let reportStem = folderNames[rootFolder, default: VaultFolderNames()].claim(stem: options.reportName, pathExtension: "md")
        let reportPath = rootFolder.appending(reportStem) ?? rootFolder
        try await destination.createFolder(at: rootFolder)

        var wasCancelled = false
        let total = order.count
        for (index, identifier) in order.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            defer { options.progress?(index + 1, total) }
            guard let item = items[identifier] else { continue }
            do {
                switch item.kind {
                case .page: try await writePage(item)
                case .database: try await writeDatabase(item)
                }
            } catch let error as NotionAPIError {
                switch error {
                case .unauthorized, .unavailable:
                    stoppedBecause = error.description
                    report.record(.failed, at: item.path, "the import stopped here: \(error.description)")
                case .notShared:
                    report.record(.leftOut, at: item.path, "“\(item.title)” was not imported: \(error.description)")
                default:
                    report.record(.failed, at: item.path, "“\(item.title)” could not be imported: \(error.description)")
                }
                if stoppedBecause != nil { break }
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch {
                report.record(.failed, at: item.path, "“\(item.title)” could not be imported: \(ImportReport.text(describing: error)).")
            }
        }

        if !propertyTypes.isEmpty {
            do {
                for name in try await destination.assignPropertyTypes(propertyTypes) {
                    report.record(.simplified, at: nil, "the property “\(name)” already has another type in this vault, which it keeps")
                }
            } catch {
                report.record(.failed, at: nil, "the property types could not be written: \(ImportReport.text(describing: error)).")
            }
        }
        if wasCancelled {
            report.record(.leftOut, at: nil, "the import was stopped before its end: the pages and databases not listed here were not imported.")
        }
        if let stoppedBecause {
            report.record(.failed, at: nil, "the import ended early: \(stoppedBecause)")
        }
        try await writeRecord()
        if updater != nil {
            report.source += " It updates the earlier import in this folder: \(updateCounts.replaced) replaced, \(updateCounts.unchanged) unchanged, "
                + "\(updateCounts.kept) kept as changed in the vault."
        }
        try await destination.writeNewFile(Array(report.markdown.utf8), at: reportPath)
        return NotionAPIImportResult(report: report, reportPath: reportPath, propertyTypes: propertyTypes, wasCancelled: wasCancelled,
                                     stoppedBecause: stoppedBecause)
    }

    // MARK: Discovery

    /// Finds every page and database shared with the integration, and how they nest.
    mutating func discover() async throws {
        let results = try await client.allResults(post: "search")
        var databaseIdentifiers: Set<String> = []
        for result in results {
            guard let identifier = result["id"]?.string else { continue }
            switch result["object"]?.string {
            case "page":
                let key = NotionAPIImportRun.key(identifier)
                items[key] = NotionAPIItem(identifier: identifier, kind: .page, title: NotionAPIPropertyReader.title(of: result["properties"] ?? .null),
                                           parent: try await parentKey(of: result["parent"] ?? .null), json: result)
            case "data_source":
                if let database = result["parent"]?["database_id"]?.string {
                    databaseIdentifiers.insert(database)
                    databaseOfDataSource[NotionAPIImportRun.key(identifier)] = NotionAPIImportRun.key(database)
                }
            case "database":
                databaseIdentifiers.insert(identifier)
            default:
                continue
            }
        }
        for database in databaseIdentifiers.sorted() {
            let json: JSONValue
            do {
                json = try await client.get("databases/\(database)")
            } catch let error as NotionAPIError {
                switch error {
                case .unauthorized, .unavailable: throw error
                default:
                    report.record(.leftOut, at: nil, "a database (\(database)) was not imported: \(error.description)")
                    continue
                }
            }
            let key = NotionAPIImportRun.key(database)
            let title = NotionAPIPropertyReader.plainText(json["title"] ?? .null)
            // The search names the database a data source belongs to: a linked database lists another's.
            for source in json["data_sources"]?.elements ?? [] {
                if let sourceIdentifier = source["id"]?.string, databaseOfDataSource[NotionAPIImportRun.key(sourceIdentifier)] == nil {
                    databaseOfDataSource[NotionAPIImportRun.key(sourceIdentifier)] = key
                }
            }
            items[key] = NotionAPIItem(identifier: database, kind: .database, title: title.isEmpty ? "Untitled" : title,
                                       parent: try await parentKey(of: json["parent"] ?? .null), json: json)
        }
        // A row's parent is its data source, which stands for its database.
        for (key, item) in items {
            if let parent = item.parent, let database = databaseOfDataSource[parent] { items[key]?.parent = database }
        }
        if !options.rootIdentifiers.isEmpty {
            let roots = Set(options.rootIdentifiers.map(NotionAPIImportRun.key))
            func isChosen(_ key: String) -> Bool {
                var current: String? = key
                var steps = 0
                while let candidate = current, steps < 64 {
                    if roots.contains(candidate) { return true }
                    current = items[candidate]?.parent
                    steps += 1
                }
                return false
            }
            items = items.filter { isChosen($0.key) }
        }
        // A parent outside the import leaves its child at the top.
        for (key, item) in items where item.parent.map({ items[$0] == nil }) ?? false { items[key]?.parent = nil }
        try await findLinkedDatabases()
    }

    /// Takes out of the import's items the databases that show another database's data source, keeping their views
    /// for that database's base.
    mutating func findLinkedDatabases() async throws {
        for (key, item) in items.sorted(by: { $0.key < $1.key }) where item.kind == .database {
            if try await registerLinkedDatabase(item.json, title: item.title) { items[key] = nil }
        }
    }

    /// The database a linked database shows: the one database owning all of `database`'s data sources, when it is
    /// another one of the import.
    func owner(ofLinkedDatabase database: JSONValue) -> String? {
        guard let identifier = database["id"]?.string else { return nil }
        let sources = (database["data_sources"]?.elements ?? []).compactMap { $0["id"]?.string.map(NotionAPIImportRun.key) }
        let owners = Set(sources.compactMap { databaseOfDataSource[$0] })
        guard !sources.isEmpty, owners.count == 1, let owner = owners.first, owner != NotionAPIImportRun.key(identifier),
            items[owner]?.kind == .database
        else { return nil }
        return owner
    }

    /// Keeps `database` as a linked database with its views when it shows another database's data source, and says
    /// whether it does.
    mutating func registerLinkedDatabase(_ database: JSONValue, title: String) async throws -> Bool {
        guard let identifier = database["id"]?.string, let owner = owner(ofLinkedDatabase: database) else { return false }
        guard !writtenBases.contains(owner) else {
            // Found on a page written after the base it shows: embedded as that base, without views of its own.
            linkedDatabases[NotionAPIImportRun.key(identifier)] = NotionAPILinkedDatabase(owner: owner, title: title, views: [], embeddedView: nil)
            report.record(.simplified, at: items[owner]?.path, "the linked database “\(title)” is embedded as this base, without its own views")
            return true
        }
        do {
            var views: [JSONValue] = []
            for listed in try await client.allResults(get: "views", query: [("database_id", identifier)]) {
                if let viewIdentifier = listed["id"]?.string { views.append(try await client.get("views/\(viewIdentifier)")) }
            }
            // Each view is named after the linked database too, so that it stands apart from the owner's own views.
            var renamed: [JSONValue] = []
            for view in views {
                let viewName = view["name"]?.string ?? "View"
                var name = viewName + " (" + title + ")"
                var number = 2
                while linkedViewNames.contains(name.lowercased()) {
                    name = viewName + " (" + title + " " + String(number) + ")"
                    number += 1
                }
                linkedViewNames.insert(name.lowercased())
                guard case .object(let members) = view else { continue }
                renamed.append(.object(members.filter { $0.key != "name" } + [("name", .string(name))]))
            }
            views = renamed
            linkedDatabases[NotionAPIImportRun.key(identifier)] = NotionAPILinkedDatabase(owner: owner, title: title, views: views,
                                                                                          embeddedView: views.first?["name"]?.string)
        } catch let error as NotionAPIError {
            if case .unauthorized = error { throw error }
            if case .unavailable = error { throw error }
            linkedDatabases[NotionAPIImportRun.key(identifier)] = NotionAPILinkedDatabase(owner: owner, title: title, views: [], embeddedView: nil)
        }
        return true
    }

    /// Reads the databases `blocks` embed that discovery did not find, Notion's search giving no linked database,
    /// and keeps those showing a database of the import as linked databases.
    mutating func readEmbeddedDatabases(in blocks: [NotionAPIBlock], at path: VaultPath) async throws {
        for block in blocks {
            if block.type == "child_database", target(ofDatabase: block.identifier) == nil,
                linkedDatabases[NotionAPIImportRun.key(block.identifier)] == nil
            {
                do {
                    let database = try await client.get("databases/\(block.identifier)")
                    let title = NotionAPIPropertyReader.plainText(database["title"] ?? .null)
                    _ = try await registerLinkedDatabase(database, title: title.isEmpty ? (block.content["title"]?.string ?? "Untitled") : title)
                } catch let error as NotionAPIError {
                    switch error {
                    case .unauthorized, .unavailable: throw error
                    default: report.record(.leftOut, at: path, "a database (\(block.identifier)) was not imported: \(error.description)")
                    }
                }
            }
            try await readEmbeddedDatabases(in: block.children, at: path)
            for section in block.sections { try await readEmbeddedDatabases(in: section.blocks, at: path) }
        }
    }

    /// The key of the page, data source or database holding an object, `nil` at the top. A page inside a block is
    /// held by the page the block is in, found by going up the blocks.
    func parentKey(of parent: JSONValue) async throws -> String? {
        switch parent["type"]?.string {
        case "page_id": return parent["page_id"]?.string.map(NotionAPIImportRun.key)
        case "data_source_id": return parent["data_source_id"]?.string.map(NotionAPIImportRun.key)
        case "database_id": return parent["database_id"]?.string.map(NotionAPIImportRun.key)
        case "block_id":
            var block = parent["block_id"]?.string
            var steps = 0
            while let identifier = block, steps < 16 {
                let json = try await client.get("blocks/\(identifier)")
                let next = json["parent"] ?? .null
                if next["type"]?.string == "page_id" { return next["page_id"]?.string.map(NotionAPIImportRun.key) }
                block = next["block_id"]?.string
                steps += 1
            }
            return nil
        default: return nil
        }
    }

    // MARK: Plan

    /// Gives each page and database its note or base and its folder, parents before children.
    mutating func plan() async throws {
        var children: [String?: [String]] = [:]
        for (key, item) in items { children[item.parent, default: []].append(key) }
        for key in children.keys { children[key]?.sort { (items[$0]?.title ?? "", $0) < (items[$1]?.title ?? "", $1) } }
        folderNames[rootFolder] = VaultFolderNames(existingNames: try await destination.names(inFolderAt: rootFolder))
        var queue: [(key: String, folder: VaultPath)] = (children[nil] ?? []).map { ($0, rootFolder) }
        var position = 0
        while position < queue.count {
            let (key, folder) = queue[position]
            position += 1
            guard var item = items[key] else { continue }
            if folderNames[folder] == nil { folderNames[folder] = VaultFolderNames(existingNames: try await destination.names(inFolderAt: folder)) }
            let stem = VaultFileName.stem(forTitle: item.title)
            let extensionName = item.kind == .database ? "base" : "md"
            if let previous = earlier[key]?.path, previous.name.hasSuffix("." + extensionName), let parent = previous.parent,
                let previousFolder = parent.appending(String(previous.name.dropLast(extensionName.count + 1)))
            {
                // Where the earlier import put it, whatever its title now: its name and its folder's are taken already.
                item.path = previous
                item.folder = previousFolder
            } else {
                let claimed = folderNames[folder, default: VaultFolderNames()].claimStem(stem, withEachOf: [extensionName, nil])
                item.path = folder.appending("\(claimed).\(extensionName)") ?? folder
                item.folder = folder.appending(claimed) ?? folder
            }
            items[key] = item
            order.append(key)
            queue += (children[key] ?? []).map { ($0, item.folder) }
        }
        // Pages before databases: a page can embed a linked database whose views go into a database's base, which
        // is written once. A database's rows still follow it, as they read its formulas.
        func isPage(_ key: String) -> Bool {
            items[key]?.kind == .page && items[key]?.parent.flatMap { items[$0]?.kind } != .database
        }
        order = order.filter { isPage($0) } + order.filter { !isPage($0) }
        // Link targets: the name alone when no other file of the import has it, else the path.
        var counts: [String: Int] = [:]
        for item in items.values { counts[item.path.name.lowercased(), default: 0] += 1 }
        for (key, item) in items {
            let isNote = item.kind == .page
            let name = isNote ? String(item.path.name.dropLast(3)) : item.path.name
            if counts[item.path.name.lowercased()] == 1 {
                linkTargets[key] = name
            } else {
                let full = item.path.description
                linkTargets[key] = isNote ? String(full.dropLast(3)) : full
            }
        }
    }

    // MARK: Pages

    /// Reads a block's children, page by page, and theirs, as the page's content needs them.
    func blocks(of identifier: String, depth: Int = 0) async throws -> [NotionAPIBlock] {
        var result: [NotionAPIBlock] = []
        for json in try await client.allResults(get: "blocks/\(identifier)/children") {
            var block = NotionAPIBlock(json: json)
            let type = block.type
            if type == "transcription" || type == "meeting_notes" {
                let sections = block.content["children"] ?? .null
                for (title, member) in [("Summary", "summary_block_id"), ("Notes", "notes_block_id"), ("Transcript", "transcript_block_id")] {
                    if let sectionBlock = sections[member]?.string, depth < 12 {
                        block.sections.append((title, try await blocks(of: sectionBlock, depth: depth + 1)))
                    }
                }
            } else if type == "synced_block", let original = block.content["synced_from"]?["block_id"]?.string, depth < 12 {
                block.children = try await blocks(of: original, depth: depth + 1)
            } else if block.hasChildren, type != "child_page", type != "child_database", depth < 12 {
                block.children = try await blocks(of: block.identifier, depth: depth + 1)
            }
            result.append(block)
        }
        return result
    }

    /// Every file Notion holds that the blocks show, by its address, with the name to save it under.
    static func files(in blocks: [NotionAPIBlock]) -> [(url: String, name: String)] {
        var result: [(url: String, name: String)] = []
        for block in blocks {
            if ["image", "file", "pdf", "video", "audio"].contains(block.type), let url = block.content["file"]?["url"]?.string {
                result.append((url, block.content["name"]?.string ?? fileName(ofAddress: url)))
            }
            result += files(in: block.children)
            for section in block.sections { result += files(in: section.blocks) }
        }
        return result
    }

    /// The file name an address ends with, its escapes decoded: `…/abc/Diagram%201.png?X-Amz…` gives `Diagram 1.png`.
    static func fileName(ofAddress url: String) -> String {
        let path = url.pieces(separatedBy: "?")[0]
        let last = path.pieces(separatedBy: "/").last ?? "file"
        let decoded = last.percentDecoded ?? last
        return decoded.isEmpty ? "file" : decoded
    }

    /// Downloads `files` into `folder`, at free names, and records where each went. A file that cannot be downloaded is
    /// reported by the page that shows it.
    mutating func download(_ files: [(url: String, name: String)], into folder: VaultPath, for path: VaultPath) async throws {
        var madeFolder = false
        for file in files where fileTargets[file.url] == nil {
            do {
                if !madeFolder {
                    try await destination.createFolder(at: folder)
                    if folderNames[folder] == nil { folderNames[folder] = VaultFolderNames(existingNames: try await destination.names(inFolderAt: folder)) }
                    madeFolder = true
                }
                let parts = file.name.pieces(separatedBy: ".")
                let pathExtension = parts.count > 1 ? parts.last : nil
                let stem = VaultFileName.stem(forTitle: parts.count > 1 ? parts.dropLast().joined(separator: ".") : file.name)
                // An update keeps the file an earlier import downloaded under the same name.
                let earlierName = stem + (pathExtension.map { "." + $0 } ?? "")
                if updater != nil, try await destination.names(inFolderAt: folder).contains(earlierName), let earlierPath = folder.appending(earlierName) {
                    fileTargets[file.url] = earlierPath.description
                    continue
                }
                let name = folderNames[folder, default: VaultFolderNames()].claim(stem: stem, pathExtension: pathExtension)
                guard let filePath = folder.appending(name) else { continue }
                let writer = try await destination.createNewFile(at: filePath)
                try await client.download(file.url) { piece in try await writer.append(piece) }
                try await writer.close()
                report.recordWritten(.attachment, at: filePath)
                fileTargets[file.url] = filePath.description
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NotionAPIError {
                if case .unauthorized = error { throw error }
                report.record(.failed, at: path, "the file \(file.name) could not be downloaded: \(error.description)")
            }
        }
    }

    mutating func writePage(_ item: NotionAPIItem) async throws {
        let content = try await blocks(of: item.identifier)
        try await readEmbeddedDatabases(in: content, at: item.path)
        try await download(NotionAPIImportRun.files(in: content), into: item.folder, for: item.path)
        var frontMatter = FrontMatter()
        frontMatter.set("notion-id", to: .text(item.identifier))
        if let emoji = item.json["icon"]?["emoji"]?.string { frontMatter.set("icon", to: .text(emoji)) }
        if let cover = item.json["cover"]?["external"]?["url"]?.string { frontMatter.set("cover", to: .text(cover)) }
        if let parent = item.parent, items[parent]?.kind == .database {
            let formulas = NotionAPIImportRun.convertibleFormulas(of: items[parent]?.json ?? .null)
            var reader = NotionAPIPropertyReader(resolver: self, formulaNames: Set(formulas.keys))
            for property in reader.read(item.json["properties"] ?? .null) {
                frontMatter.set(property.name, to: property.value)
                assign(property.name, property.type, at: item.path)
            }
            for finding in reader.findings { report.record(finding.severity, at: item.path, finding.message) }
        }
        let read = NotionAPIPageReader.read(content, resolver: self)
        for finding in read.findings { report.record(finding.severity, at: item.path, finding.message) }
        let text = frontMatter.yaml + MarkdownWriter.markdown(for: read.blocks)
        if let folder = item.path.parent { try await destination.createFolder(at: folder) }
        try await save(Array(text.utf8), of: item, kind: .note)
    }

    mutating func assign(_ name: String, _ type: PropertyType, at path: VaultPath) {
        switch (propertyTypes[name], type) {
        case (nil, _): propertyTypes[name] = type
        case (.date?, .datetime): propertyTypes[name] = .datetime
        case (let existing?, _) where existing == type || (existing == .datetime && type == .date): break
        case (let existing?, _):
            report.record(.simplified, at: path, "the property “\(name)” is \(type.rawValue) here but \(existing.rawValue) in an earlier note, "
                + "and a vault gives a property one type: it is typed \(existing.rawValue)")
        }
    }

    // MARK: Databases

    /// The formulas and rollups of a database's first data source that Bases can compute, by name, converted.
    static func convertibleFormulas(of database: JSONValue) -> [String: String] {
        let schema = database["data_source_schema"] ?? .null
        var names: [String: String] = [:]
        for (name, property) in schema.members { if let identifier = property["id"]?.string { names[identifier] = name } }
        let formulaNames = Set(schema.members.filter { $0.value["type"]?.string == "formula" }.map { $0.key })
        var result: [String: String] = [:]
        for (name, formula) in database["rollup_formulas"]?.members ?? [] { if let text = formula.string { result[name] = text } }
        for (name, property) in schema.members where property["type"]?.string == "formula" {
            if let expression = property["formula"]?["expression"]?.string,
                let converted = try? NotionFormulaConverter.convert(expression, propertyNames: names, formulaNames: formulaNames)
            {
                result[name] = converted
            }
        }
        return result
    }

    mutating func writeDatabase(_ item: NotionAPIItem) async throws {
        let sources = item.json["data_sources"]?.elements ?? []
        guard let source = sources.first?["id"]?.string else {
            report.record(.leftOut, at: item.path, "the database “\(item.title)” has no data source the integration can read")
            return
        }
        if sources.count > 1 {
            report.record(.simplified, at: item.path, "the database “\(item.title)” has \(sources.count) data sources: the base shows the first, "
                + "and the rows of the others are imported as notes beside it")
        }
        let schema = try await client.get("data_sources/\(source)")
        var database = item.json
        // The schema and the rollups, kept with the database for its rows' formulas.
        let rollups = try await rollupFormulas(of: schema["properties"] ?? .null, database: item)
        if case .object(var members) = database {
            members.append(("data_source_schema", schema["properties"] ?? .null))
            members.append(("rollup_formulas", .object(rollups.map { ($0.name, JSONValue.string($0.formula)) })))
            database = .object(members)
            items[NotionAPIImportRun.key(item.identifier)]?.json = database
        }
        var views: [JSONValue] = []
        do {
            for listed in try await client.allResults(get: "views", query: [("database_id", item.identifier)]) {
                if let identifier = listed["id"]?.string { views.append(try await client.get("views/\(identifier)")) }
            }
        } catch let error as NotionAPIError {
            if case .unauthorized = error { throw error }
            report.record(.simplified, at: item.path, "the views of “\(item.title)” could not be read (\(error.description)): the base has one table view")
        }
        for (_, linked) in linkedDatabases.sorted(by: { $0.key < $1.key }) where linked.owner == NotionAPIImportRun.key(item.identifier) {
            if views.isEmpty {
                // The base's own first view stays the one its embeds open on.
                views.append(.object([("object", .string("view")), ("name", .string("Table")), ("type", .string("table"))]))
            }
            views += linked.views
            let names = linked.views.compactMap { $0["name"]?.string }.map { "“" + $0 + "”" }
            report.record(.simplified, at: item.path, "the linked database “\(linked.title)” is embedded where its page had it as this base"
                + (names.isEmpty ? "" : ", opening on " + (names.count == 1 ? "its view " : "its views ") + names.joined(separator: ", ")))
        }
        let base = NotionAPIBaseWriter.base(for: database, schema: schema["properties"] ?? .null, views: views, dataSource: source,
                                            rowsFolder: item.folder, formulas: NotionAPIImportRun.convertibleFormulas(of: database))
        for finding in base.findings { report.record(finding.severity, at: item.path, finding.message) }
        if let folder = item.path.parent { try await destination.createFolder(at: folder) }
        try await destination.createFolder(at: item.folder)
        try await save(Array(base.file.yaml.utf8), of: item, kind: .base)
        writtenBases.insert(NotionAPIImportRun.key(item.identifier))
        for (name, property) in (schema["properties"] ?? .null).members {
            guard let type = property["type"]?.string, type != "title" else { continue }
            // A computed property is either the base's formula or, in each row, the value it had: the rows type it.
            if type == "formula" || type == "rollup" { continue }
            let propertyName = type == "multi_select" && name.lowercased() == "tags" ? "tags" : name
            assign(propertyName, NotionAPIPropertyReader.propertyType(ofNotionType: type, name: name), at: item.path)
        }
    }

    // MARK: Rollups

    /// The rollups of a data source whose properties are `properties`, as formulas of its base, by name. A rollup
    /// Bases cannot compute is reported, and its rows keep the value it had.
    mutating func rollupFormulas(of properties: JSONValue, database item: NotionAPIItem) async throws -> [(name: String, formula: String)] {
        var names: [String: String] = [:]
        for (name, property) in properties.members { if let identifier = property["id"]?.string { names[identifier] = name } }
        var result: [(name: String, formula: String)] = []
        for (name, property) in properties.members where property["type"]?.string == "rollup" {
            let rollup = property["rollup"] ?? .null
            let relation = rollup["relation_property_name"]?.string ?? rollup["relation_property_id"]?.string.flatMap { names[$0] }
            guard let relation, let function = rollup["function"]?.string else { continue }
            func refuse(_ reason: String) {
                report.record(.simplified, at: item.path, "the rollup “\(name)” \(reason), so each note holds its value when imported")
            }
            var related: JSONValue?
            if let source = properties[relation]?["relation"]?["data_source_id"]?.string { related = try await relatedProperties(source) }
            var targetName = rollup["rollup_property_name"]?.string
            if targetName == nil, let identifier = rollup["rollup_property_id"]?.string {
                targetName = related?.members.first { $0.value["id"]?.string == identifier }?.key
            }
            guard let targetName else {
                refuse("reads a property of “\(relation)” the integration cannot see")
                continue
            }
            let target: NotionRollupConverter.Target
            switch related?[targetName]?["type"]?.string {
            case "title"?: target = .title
            case "formula"?, "rollup"?:
                refuse("reads “\(targetName)”, which the related notes compute rather than hold")
                continue
            case "multi_select"? where targetName.lowercased() == "tags": target = .property("tags")
            default: target = .property(targetName)
            }
            guard let formula = NotionRollupConverter.formula(relation: relation, target: target, function: function) else {
                refuse("uses Notion's \(function.replacingEvery("_", with: " ")), which Bases has no counterpart for")
                continue
            }
            result.append((name, formula))
        }
        return result
    }

    /// The properties of the data source `identifier`, `nil` when the integration cannot read it.
    mutating func relatedProperties(_ identifier: String) async throws -> JSONValue? {
        let key = NotionAPIImportRun.key(identifier)
        if let known = dataSourceProperties[key] { return known }
        var properties: JSONValue?
        do {
            properties = try await client.get("data_sources/\(identifier)")["properties"]
        } catch let error as NotionAPIError {
            switch error {
            case .unauthorized, .unavailable: throw error
            default: properties = nil
            }
        }
        dataSourceProperties[key] = .some(properties)
        return properties
    }
}
