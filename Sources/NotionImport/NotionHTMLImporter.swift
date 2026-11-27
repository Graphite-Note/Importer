/**
 * File: NotionHTMLImporter.swift
 * ------------------------------
 * Layer: Notion
 * Description: Imports Notion's HTML export into a vault: reads every page once to place it, then converts each page
 *              into a note (a database into a base, its rows into notes with typed properties), copies the
 *              attachments in pieces, assigns the property types and writes the import report.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

import ImporterCore

/// Why an export cannot be imported at all.
public enum NotionImportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The export is Notion's "Markdown & CSV" export, which leaves out data the HTML export keeps.
    case markdownExport
    /// The export holds no Notion page.
    case noPages

    public var description: String {
        switch self {
        case .markdownExport:
            return "This is Notion's Markdown & CSV export, which leaves out the types of database properties, callout "
                + "icons, colors and equations. Export again from Notion's Settings, Export all workspace content, with "
                + "the format HTML, and import that file."
        case .noPages:
            return "This file holds no Notion page. Notion's export is the .zip that Settings, Export all workspace "
                + "content gives, with the format HTML."
        }
    }
}

/// How an import runs.
public struct NotionHTMLImportOptions: Sendable {
    /// The vault folder the import writes in, made when missing. The vault's own folder when empty.
    public var destinationFolder: VaultPath
    /// The export's name, for the report.
    public var exportName: String
    /// The day of the import as the report states it (`2026-11-26`), given by the host so that the report reads the
    /// same in tests.
    public var importDate: String
    /// The year given to dates the export writes without one: the year it was exported.
    public var exportYear: Int
    /// The name of the report note, without extension.
    public var reportName: String
    /// Called after each page with the pages done and the pages in all.
    public var progress: (@Sendable (_ done: Int, _ total: Int) -> Void)?

    public init(destinationFolder: VaultPath, exportName: String, importDate: String, exportYear: Int,
                reportName: String = "Notion import report", progress: (@Sendable (Int, Int) -> Void)? = nil) {
        self.destinationFolder = destinationFolder
        self.exportName = exportName
        self.importDate = importDate
        self.exportYear = exportYear
        self.reportName = reportName
        self.progress = progress
    }
}

/// What an import did.
public struct NotionHTMLImportResult: Sendable {
    /// The report, as written in the vault.
    public var report: ImportReport
    /// Where the report note is.
    public var reportPath: VaultPath
    /// The type given to each property of the imported notes.
    public var propertyTypes: [String: PropertyType]
    /// Whether the import stopped early because its task was cancelled.
    public var wasCancelled: Bool
}

/// Imports Notion's HTML export.
public enum NotionHTMLImporter {
    /// Imports the export whose files are `tree` into `destination`.
    public static func importExport(_ tree: ExportFileTree, into destination: any ImportDestination,
                                    options: NotionHTMLImportOptions) async throws -> NotionHTMLImportResult {
        var export = try NotionExport(tree)
        var report = ImportReport(title: "Notion import",
                                  source: "Imported from \(options.exportName) on \(options.importDate).")
        for skipped in tree.skippedEntries {
            report.record(.leftOut, at: nil, "\(skipped.origin) was not read: \(skipped.reason).")
        }

        // First pass: each page's title, kind and headings, so that every page has its place before any is written.
        var dateParser = NotionDateParser(defaultYear: options.exportYear)
        var summaries: [String: NotionPageSummary] = [:]
        var unnamedPages: [(file: ExportFile, identifier: String)] = []
        for file in export.unnamedHTMLFiles {
            guard let html = try? String(decoding: await file.contents(), as: UTF8.self),
                let identifier = NotionPageSummary.pageIdentifier(in: html)
            else { continue }
            unnamedPages.append((file, identifier))
        }
        export.adoptUnnamedPages(unnamedPages)
        guard !export.pages.isEmpty else { throw NotionImportError.noPages }
        for page in export.pages {
            do {
                let html = String(decoding: try await page.file.contents(), as: UTF8.self)
                let summary = NotionPageSummary(html: html, titleFromName: page.titleFromName)
                for date in summary.propertyDates { dateParser.observe(date) }
                summaries[page.identifier] = summary
            } catch {
                report.record(.failed, at: nil, "\(page.file.origin) could not be read: \(ImportReport.text(describing: error)).")
            }
            if Task.isCancelled { break }
        }

        var plan = try await NotionVaultPlan(export: export, summaries: summaries, destination: destination,
                                             root: options.destinationFolder)
        let reportStem = plan.claimReportName(options.reportName)
        let reportPath = plan.rootFolder.appending("\(reportStem).md") ?? plan.rootFolder

        for folder in plan.foldersToCreate {
            try await destination.createFolder(at: folder)
        }

        // Second pass: each page converted and written.
        var propertyTypes: [String: PropertyType] = [:]
        var reportedTypeConflicts: Set<String> = []
        func assign(_ name: String, _ type: PropertyType, at path: VaultPath, report: inout ImportReport) {
            switch (propertyTypes[name], type) {
            case (nil, _):
                propertyTypes[name] = type
            case (.date?, .datetime):
                propertyTypes[name] = .datetime
            case (let existing?, _) where existing == type || (existing == .datetime && type == .date):
                break
            case (let existing?, _):
                if reportedTypeConflicts.insert(name).inserted {
                    report.record(.simplified, at: path, "the property “\(name)” is \(type.rawValue) here but "
                        + "\(existing.rawValue) in an earlier note, and a vault gives a property one type: it is typed \(existing.rawValue)")
                }
            }
        }

        var wasCancelled = false
        let total = export.pages.count
        for (index, page) in export.pages.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            defer { options.progress?(index + 1, total) }
            guard let placement = plan.placement(ofPage: page.identifier) else { continue }
            do {
                let html = String(decoding: try await page.file.contents(), as: UTF8.self)
                let read = NotionPageReader.read(html: html, exportPath: page.file.pathComponents, resolver: plan,
                                                 dateParser: dateParser)
                for finding in read.findings {
                    report.record(finding.severity, at: placement.path, finding.message)
                }
                if let database = read.database {
                    try await writeBase(database, page: read, placement: placement, export: export, plan: &plan,
                                        dateParser: dateParser, destination: destination, report: &report,
                                        assignType: { name, type, path, report in assign(name, type, at: path, report: &report) })
                } else {
                    let contents = read.frontMatter.yaml + MarkdownWriter.markdown(for: read.blocks)
                    try await destination.writeNewFile(Array(contents.utf8), at: placement.path)
                    report.recordWritten(.note, at: placement.path)
                    for (name, type) in read.propertyTypes { assign(name, type, at: placement.path, report: &report) }
                }
            } catch {
                report.record(.failed, at: placement.path, "\(page.file.origin) could not be imported: \(ImportReport.text(describing: error)).")
            }
        }

        // Attachments, copied piece by piece.
        for attachment in export.attachments where !wasCancelled {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            guard let path = plan.attachmentPath(atExportPath: attachment.pathComponents) else { continue }
            do {
                var reader = try await attachment.openReader()
                let writer = try await destination.createNewFile(at: path)
                while let piece = try await reader.read() {
                    try await writer.append(piece)
                }
                try await writer.close()
                report.recordWritten(.attachment, at: path)
            } catch {
                report.record(.failed, at: path, "\(attachment.origin) could not be copied: \(ImportReport.text(describing: error)).")
            }
        }

        if !propertyTypes.isEmpty {
            do {
                let kept = try await destination.assignPropertyTypes(propertyTypes)
                for name in kept {
                    report.record(.simplified, at: nil, "the property “\(name)” already has another type in this vault, which it keeps")
                }
            } catch {
                report.record(.failed, at: nil, "the property types could not be written: \(ImportReport.text(describing: error)).")
            }
        }
        if wasCancelled {
            report.record(.leftOut, at: nil, "the import was stopped before its end: the pages and attachments not listed here were not imported.")
        }
        try await destination.writeNewFile(Array(report.markdown.utf8), at: reportPath)
        return NotionHTMLImportResult(report: report, reportPath: reportPath, propertyTypes: propertyTypes,
                                      wasCancelled: wasCancelled)
    }

    private static func writeBase(_ database: NotionDatabaseTable, page: NotionPage, placement: NotionVaultPlan.Placement,
                                  export: NotionExport, plan: inout NotionVaultPlan, dateParser: NotionDateParser,
                                  destination: any ImportDestination, report: inout ImportReport,
                                  assignType: (String, PropertyType, VaultPath, inout ImportReport) -> Void) async throws {
        let rowsFolder = placement.childFolder ?? placement.path.parent ?? plan.rootFolder
        var displayNames: [(property: String, displayName: String)] = []
        var order = ["file.name"]
        for column in database.columns {
            if column.isTitle {
                displayNames.append(("file.name", column.name))
                continue
            }
            let name = column.notionType == "multi_select" && column.name.lowercased() == "tags" ? "tags" : column.name
            if name != column.name { displayNames.append((name, column.name)) }
            order.append(name)
        }
        let base = BaseFile(folder: rowsFolder, displayNames: displayNames, views: [BaseFile.View(type: "table", name: "Table", order: order)])
        try await destination.writeNewFile(Array(base.yaml.utf8), at: placement.path)
        report.recordWritten(.base, at: placement.path)
        if !MarkdownInlineNormalizer.isBlank(page.blocks.flatMap { block -> [MarkdownInline] in
            if case .paragraph(let inlines) = block { return inlines }
            return [.text("x")]
        }) {
            report.record(.simplified, at: placement.path, "the text on the database's page, above or below its table, was left out: a base holds no text")
        }

        // Rows the table lists whose page the export lacks, read from the database's CSV.
        guard let csvFile = export.csvFiles[page.identifier ?? ""] else { return }
        let table = CSVTable(String(decoding: try await csvFile.contents(), as: UTF8.self))
        guard let titleColumn = database.columns.first(where: { $0.isTitle })?.name ?? table.header.first else { return }
        var pageTitles = Dictionary(grouping: database.rowPageIdentifiers.compactMap { identifier in
            plan.placement(ofPage: identifier) != nil ? plan.title(ofPage: identifier) : nil
        }, by: { $0 }).mapValues({ $0.count })
        var columnTypes: [String: String] = [:]
        for column in database.columns { columnTypes[column.name] = column.notionType }
        for row in table.rows {
            let title = table.value(titleColumn, in: row)
            if let count = pageTitles[title], count > 0 {
                pageTitles[title] = count - 1
                continue
            }
            var frontMatter = FrontMatter()
            for column in table.header where column != titleColumn {
                let text = table.value(column, in: row).trimmingSpacesAndLineBreaks()
                guard let (name, value, type) = csvProperty(column, text: text, notionType: columnTypes[column], dateParser: dateParser) else { continue }
                frontMatter.set(name, to: value)
                assignType(name, type, rowsFolder, &report)
            }
            let path = plan.claimNote(titled: title, in: rowsFolder)
            try await destination.writeNewFile(Array(frontMatter.yaml.utf8), at: path)
            report.recordWritten(.note, at: path)
            report.record(.simplified, at: path, "this row has no page in the export, so it was made from the database's CSV, with its properties only")
        }
    }

    private static func csvProperty(_ column: String, text: String, notionType: String?,
                                    dateParser: NotionDateParser) -> (String, PropertyValue, PropertyType)? {
        guard !text.isEmpty else { return nil }
        switch notionType {
        case "checkbox"?:
            return (column, .checkbox(text.lowercased() == "yes" || text.lowercased() == "true"), .checkbox)
        case "number"?, "auto_increment_id"?:
            if let number = NotionPropertyReader.number(text) { return (column, .number(number), .number) }
            return (column, .text(text), .number)
        case "date"?, "created_time"?, "last_edited_time"?:
            if let dates = dateParser.parseRange(text), dates.count == 1 {
                return (column, .date(dates[0].propertyText), dates[0].time == nil ? .date : .datetime)
            }
            return (column, .text(text), .date)
        case "multi_select"?:
            let values = text.pieces(separatedBy: ", ").filter { !$0.isEmpty }
            if column.lowercased() == "tags" {
                return ("tags", .list(values.map { $0.replacingEvery(" ", with: "-") }), .tags)
            }
            return (column, .list(values), .multitext)
        default:
            return (column, .text(text), .text)
        }
    }
}

/// What the first pass keeps of a page: its title, whether it is a database's page, its headings and the dates of its
/// properties.
struct NotionPageSummary: Sendable {
    var title: String
    var isDatabase: Bool
    var headingTextByBlock: [String: String]
    var propertyDates: [String]

    /// The identifier of the page an HTML file holds, from its `article` element, `nil` when it holds no Notion page.
    static func pageIdentifier(in html: String) -> String? {
        guard let start = html.range(ofText: "<article id=\""), html.contains(text: "class=\"page-body\""),
            let end = html[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        return NotionPageReader.hyphenatedIdentifier(String(html[start.upperBound..<end]))
    }

    init(html: String, titleFromName: String) {
        let title = NotionPageSummary.text(between: "<title>", and: "</title>", in: html).map {
            HTMLCharacterReferences.decode($0).trimmingSpacesAndLineBreaks()
        } ?? ""
        self.title = title.isEmpty ? titleFromName : title
        isDatabase = html.contains(text: "<div class=\"page-body\"><table class=\"collection-content\">")
        var headings: [String: String] = [:]
        for level in 1...3 {
            var searchStart = html.startIndex
            let opening = "<h\(level) id=\""
            while let range = html.range(ofText: opening, in: searchStart..<html.endIndex) {
                guard let quote = html[range.upperBound...].firstIndex(of: "\""),
                    let tagEnd = html[quote...].firstIndex(of: ">"),
                    let close = html.range(ofText: "</h\(level)>", in: tagEnd..<html.endIndex)
                else { break }
                let identifier = NotionPageReader.hyphenatedIdentifier(String(html[range.upperBound..<quote]))
                let inner = String(html[html.index(after: tagEnd)..<close.lowerBound])
                if let identifier {
                    headings[identifier] = HTMLDocument(inner).root.textContent.trimmingSpacesAndLineBreaks()
                }
                searchStart = close.upperBound
            }
        }
        headingTextByBlock = headings
        var dates: [String] = []
        if let properties = html.range(ofText: "<table class=\"properties\">"),
            let end = html.range(ofText: "</table>", in: properties.upperBound..<html.endIndex)
        {
            let table = html[properties.upperBound..<end.lowerBound]
            var searchStart = table.startIndex
            while let open = table.range(ofText: "<time>", in: searchStart..<table.endIndex),
                let close = table.range(ofText: "</time>", in: open.upperBound..<table.endIndex)
            {
                dates.append(HTMLCharacterReferences.decode(String(table[open.upperBound..<close.lowerBound])))
                searchStart = close.upperBound
            }
        }
        propertyDates = dates
    }

    private static func text(between opening: String, and closing: String, in html: String) -> String? {
        guard let start = html.range(ofText: opening), let end = html.range(ofText: closing, in: start.upperBound..<html.endIndex) else {
            return nil
        }
        return String(html[start.upperBound..<end.lowerBound])
    }
}
