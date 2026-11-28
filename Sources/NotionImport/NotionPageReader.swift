/**
 * File: NotionPageReader.swift
 * ----------------------------
 * Layer: Notion
 * Description: Reads one page of Notion's HTML export into the importer's model: its title, icon, cover and
 *              properties, and its blocks (text, headings, lists, to-dos, toggles, quotes, callouts, code, math,
 *              tables, columns, images, files, bookmarks, links to pages, databases, table of contents), with each
 *              link resolved by page identifier.
 *
 * Authors: Bahey Shalash
 * Version: 0.4
 * Date: 28/11/2026
 */

import ImporterCore

/// Where a link to a page or database of the export leads in the vault.
public struct NotionLinkTarget: Equatable, Sendable {
    /// The wiki link's target: the note's name, or its vault path when the name is not unique in the import, with the
    /// extension for a base (`Tasks.base`).
    public var linkTarget: String
    /// The page's title, shown as the link's text when it differs from the target.
    public var title: String
    /// Whether the target is a database, imported as a base.
    public var isBase: Bool
    /// The base of a database whose page is a note of its own (its text, icon or cover beside the table): the wiki
    /// link target of the base the note embeds, which an inline view of the database embeds too.
    public var baseLinkTarget: String?

    public init(linkTarget: String, title: String, isBase: Bool, baseLinkTarget: String? = nil) {
        self.linkTarget = linkTarget
        self.title = title
        self.isBase = isBase
        self.baseLinkTarget = baseLinkTarget
    }

    /// The base a view of this database embeds, `nil` for a page that is no database.
    public var embeddedBase: String? { baseLinkTarget ?? (isBase ? linkTarget : nil) }
}

/// What a page's links are resolved against: every page, database and attachment of the export, placed in the vault.
public protocol NotionLinkResolving {
    /// The target of the page or database `identifier` (hyphenated, lowercase), `nil` when the export lacks it.
    func target(ofPage identifier: String) -> NotionLinkTarget?
    /// The wiki link target of the attachment at `exportPath` (its path in the export, names as the archive spells
    /// them), `nil` when the export lacks it.
    func attachmentTarget(atExportPath exportPath: [String]) -> String?
    /// The identifier of the page at `exportPath` (its path in the export), for exports whose file names hold no
    /// identifier.
    func pageIdentifier(atExportPath exportPath: [String]) -> String?
    /// The text of the heading `blockIdentifier` (hyphenated, lowercase) of the page `pageIdentifier`, `nil` when the
    /// block is no heading.
    func headingText(inPage pageIdentifier: String, block blockIdentifier: String) -> String?
    /// The one database of the export whose title is `title`, spaces and case aside, for a linked view that names no
    /// row of it; `nil` when none or several have that title.
    func database(titled title: String) -> NotionLinkTarget?
}

extension NotionLinkResolving {
    public func database(titled title: String) -> NotionLinkTarget? { nil }
}

/// A finding of reading a page, for the import report.
public struct NotionPageFinding: Equatable, Sendable {
    public var severity: ImportReport.Severity
    public var message: String
}

/// The table of a database, as its database page shows it.
public struct NotionDatabaseTable: Equatable, Sendable {
    /// A column: its name and the type Notion's icon for it names (`typesSelect` gives `select`).
    public struct Column: Equatable, Sendable {
        public var name: String
        public var notionType: String?
        public var isTitle: Bool
    }

    /// The columns in the order the table shows them.
    public var columns: [Column]
    /// The identifier of each row's page, in the order of the table.
    public var rowPageIdentifiers: [String]
    /// The title of each row, in the order of the table.
    public var rowTitles: [String]
    /// The share of the table's width each column takes, in percent, as its `colgroup` gives it (since 2025).
    public var columnWidths: [Double?] = []
}

/// One page of Notion's HTML export, read.
public struct NotionPage: Sendable {
    /// The page's identifier (hyphenated, lowercase), from its `article` element.
    public var identifier: String?
    /// The page's title, whole (the file name's copy is shortened).
    public var title: String
    /// The page's properties, with its icon and its cover (as `banner`).
    public var frontMatter: FrontMatter
    /// The type of each property, for the vault's property types.
    public var propertyTypes: [(name: String, type: PropertyType)]
    /// The page's content.
    public var blocks: [MarkdownBlock]
    /// The database table, when the page is a database's page.
    public var database: NotionDatabaseTable?
    /// What was simplified or left out while reading.
    public var findings: [NotionPageFinding]
    /// The files the page holds inside itself (`data:` addresses), for the importer to write beside the note. Its
    /// blocks link to each by the file's `placeholder` until then.
    public var heldFiles: [NotionHeldFile] = []
    /// The tables of the databases the page shows inline, by the database's identifier: since 2025 an inline
    /// database has no page of its own, only its CSV and its rows, so its base is made from the table shown here.
    public var inlineDatabases: [String: NotionDatabaseTable] = [:]
}

/// A file a page holds inside itself, as a `data:` address: a picture pasted into Notion, written out as an attachment.
public struct NotionHeldFile: Equatable, Sendable {
    /// The wiki link target the page's blocks use for the file until the importer has placed it.
    public var placeholder: String
    /// The file's name: `Picture 1.png`, or `File 1.pdf` for a file that is no picture.
    public var name: String
    public var bytes: [UInt8]

    /// What every placeholder starts with.
    public static let placeholderPrefix = "notion-held-file:"

    /// The type and bytes of a `data:` address (`data:image/png;base64,iVBOR…`), `nil` when it holds nothing readable.
    static func decode(dataAddress address: String) -> (mediaType: String, bytes: [UInt8])? {
        guard address.lowercased().hasPrefix("data:"), let comma = address.firstIndex(of: ",") else { return nil }
        let header = address[address.index(address.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(address[address.index(after: comma)...])
        let mediaType = header.split(separator: ";").first.map { String($0).trimmingSpaces() } ?? ""
        let bytes: [UInt8]?
        if header.hasSuffix(";base64") {
            bytes = base64Decoded(payload)
        } else {
            bytes = (payload.percentDecoded ?? payload).utf8.map { $0 }
        }
        guard let bytes, !bytes.isEmpty else { return nil }
        return (mediaType.isEmpty ? "text/plain" : mediaType, bytes)
    }

    /// The extension a file of `mediaType` is named with.
    static func pathExtension(ofMediaType mediaType: String) -> String {
        let known: [String: String] = [
            "image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/gif": "gif", "image/webp": "webp",
            "image/svg+xml": "svg", "image/bmp": "bmp", "image/avif": "avif", "image/heic": "heic",
            "application/pdf": "pdf", "text/plain": "txt", "text/html": "html", "text/csv": "csv",
            "audio/mpeg": "mp3", "audio/wav": "wav", "video/mp4": "mp4", "video/webm": "webm",
        ]
        if let known = known[mediaType] { return known }
        let subtype = mediaType.split(separator: "/").last.map(String.init) ?? ""
        return !subtype.isEmpty && subtype.count <= 5 && subtype.allSatisfy({ $0.isLetter || $0.isNumber }) ? subtype : "bin"
    }

    /// The bytes of base64 text, the URL-safe alphabet and spaces allowed, `nil` for text that is not base64.
    static func base64Decoded(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bitCount = 0
        for unit in text.utf8 {
            let value: UInt32
            switch unit {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(unit - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(unit - UInt8(ascii: "a")) + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt32(unit - UInt8(ascii: "0")) + 52
            case UInt8(ascii: "+"), UInt8(ascii: "-"): value = 62
            case UInt8(ascii: "/"), UInt8(ascii: "_"): value = 63
            case UInt8(ascii: "="): return bytes
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"): continue
            default: return nil
            }
            buffer = (buffer << 6) | value
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((buffer >> UInt32(bitCount)) & 0xFF))
            }
        }
        return bytes
    }
}

/// Reads one page's HTML.
public struct NotionPageReader {
    private let document: HTMLDocument
    private let exportFolder: [String]
    private let resolver: any NotionLinkResolving
    private var dateParser: NotionDateParser
    private var findings: [NotionPageFinding] = []
    private var pageIdentifier: String?
    private var headingTextByBlock: [String: String] = [:]
    private var droppedBlockColorCount = 0
    private var inlineDatabases: [String: NotionDatabaseTable] = [:]
    private var heldFiles: [NotionHeldFile] = []

    /// Reads `html`, the page found at `exportPath` in the export.
    public static func read(html: String, exportPath: [String], resolver: any NotionLinkResolving,
                            dateParser: NotionDateParser) -> NotionPage {
        var reader = NotionPageReader(document: HTMLDocument(html), exportFolder: Array(exportPath.dropLast()),
                                      resolver: resolver, dateParser: dateParser)
        return reader.read(exportPath: exportPath)
    }

    private init(document: HTMLDocument, exportFolder: [String], resolver: any NotionLinkResolving,
                 dateParser: NotionDateParser) {
        self.document = document
        self.exportFolder = exportFolder
        self.resolver = resolver
        self.dateParser = dateParser
    }

    private mutating func read(exportPath: [String]) -> NotionPage {
        let article = document.firstElement(where: { $0.tagName == "article" })
        pageIdentifier = article?.attributes["id"].flatMap(NotionPageReader.hyphenatedIdentifier)
        let titleElement = document.firstElement(where: { $0.tagName == "title" })
        var title = (titleElement?.textContent ?? "").trimmingSpacesAndLineBreaks()
        if title.isEmpty {
            title = document.firstElement(where: { $0.hasClass("page-title") })?.textContent
                .trimmingSpacesAndLineBreaks() ?? ""
        }
        if title.isEmpty, let name = exportPath.last.flatMap(NotionExportEntryName.init) {
            title = name.title
        }
        let body = document.firstElement(where: { $0.hasClass("page-body") })
        if let body {
            for heading in body.descendants(where: { ["h1", "h2", "h3"].contains($0.tagName ?? "") }) {
                if let identifier = heading.attributes["id"].flatMap(NotionPageReader.hyphenatedIdentifier) {
                    headingTextByBlock[identifier] = heading.textContent.trimmingSpacesAndLineBreaks()
                }
            }
        }

        var frontMatter = FrontMatter()
        var propertyTypes: [(name: String, type: PropertyType)] = []
        if let table = document.firstElement(where: { $0.tagName == "table" && $0.hasClass("properties") }) {
            for row in table.descendants(where: { $0.tagName == "tr" }) {
                for property in readProperty(row) {
                    frontMatter.set(property.name, to: property.value)
                    propertyTypes.append((property.name, property.type))
                }
            }
        }
        if let header = document.firstElement(where: { $0.tagName == "header" }) {
            if frontMatter["icon"] == nil, let icon = readIcon(in: header) ?? NotionPageReader.articleIcon(article) {
                frontMatter.set("icon", to: .text(icon))
                propertyTypes.append(("icon", .text))
            }
            // The cover goes into `banner`, the property Graphite, Banners and Pixel Banner draw a note's cover from.
            if frontMatter["banner"] == nil,
                let cover = header.firstDescendant(where: { $0.hasClass("page-cover-image") })?.attributes["src"]
            {
                frontMatter.set("banner", to: .text(imageReference(cover, asWikiLink: true)))
                propertyTypes.append(("banner", .text))
            }
        }

        var blocks: [MarkdownBlock] = []
        if let description = document.firstElement(where: { $0.hasClass("page-description") }) {
            let inlines = inlines(of: description.children)
            if !MarkdownInlineNormalizer.isBlank(inlines) { blocks.append(.paragraph(inlines)) }
        }
        var database: NotionDatabaseTable?
        if let body {
            if let table = NotionPageReader.databaseTable(firstIn: body),
                let pageIdentifier, let own = resolver.target(ofPage: pageIdentifier), own.embeddedBase == nil
            {
                note(.simplified, "the export holds none of the database's rows, so its table was written as a Markdown table")
                blocks.append(databaseTable(table))
                blocks.append(contentsOf: self.blocks(of: Array(body.elementChildren.dropFirst())))
            } else if let table = NotionPageReader.databaseTable(firstIn: body) {
                database = readDatabaseTable(table)
                // Where the table was, for a page written as a note embedding its base.
                blocks.append(.paragraph([.wikiLink(target: NotionPageReader.databaseTablePlaceholder, label: nil, isEmbed: true)]))
                blocks.append(contentsOf: self.blocks(of: Array(body.elementChildren.dropFirst())))
            } else {
                blocks.append(contentsOf: self.blocks(of: body.children))
            }
        }
        if droppedBlockColorCount > 0 {
            note(.simplified, droppedBlockColorCount == 1
                ? "the color of a block was dropped: Markdown gives a block no color"
                : "the colors of \(droppedBlockColorCount) blocks were dropped: Markdown gives a block no color")
        }
        return NotionPage(identifier: pageIdentifier, title: title, frontMatter: frontMatter, propertyTypes: propertyTypes,
                          blocks: blocks, database: database, findings: findings, heldFiles: heldFiles,
                          inlineDatabases: inlineDatabases)
    }

    /// The wiki link target standing for a database's table in the blocks of its page, until the importer embeds the base.
    public static let databaseTablePlaceholder = "notion-database-table"

    /// The table of a database's page: the first element of its body, or since 2025 the table inside the
    /// `collection-content-wrapper` that is.
    static func databaseTable(firstIn body: HTMLNode) -> HTMLNode? {
        guard let first = body.elementChildren.first else { return nil }
        if first.tagName == "table", first.hasClass("collection-content") { return first }
        if first.tagName == "div", first.hasClass("collection-content-wrapper"),
            let table = first.elementChildren.first(where: { $0.tagName == "table" && $0.hasClass("collection-content") })
        {
            return table
        }
        return nil
    }

    private mutating func note(_ severity: ImportReport.Severity, _ message: String) {
        let finding = NotionPageFinding(severity: severity, message: message)
        if !findings.contains(finding) { findings.append(finding) }
    }

    // MARK: Header

    private func readIcon(in header: HTMLNode) -> String? {
        guard let holder = header.firstDescendant(where: { $0.hasClass("page-header-icon") }) else { return nil }
        if let emoji = NotionPageReader.emoji(in: holder) { return emoji }
        if let image = holder.firstDescendant(where: { $0.tagName == "img" }), let source = image.attributes["src"] {
            return imageReference(source, asWikiLink: true)
        }
        let text = holder.textContent.trimmingSpacesAndLineBreaks()
        return text.isEmpty ? nil : text
    }

    /// The emoji of an icon: the text of its `span.icon`, or, since 2025, its `data-emoji` with no text.
    static func emoji(in holder: HTMLNode) -> String? {
        if let emoji = holder.attributes["data-emoji"] ?? holder.firstDescendant(where: { $0.attributes["data-emoji"] != nil })?.attributes["data-emoji"],
            !emoji.trimmingSpaces().isEmpty
        {
            return emoji.trimmingSpaces()
        }
        return nil
    }

    /// The emoji the page's `article` names as its icon (`data-notion-page-icon`), not a picture's address.
    static func articleIcon(_ article: HTMLNode?) -> String? {
        guard let icon = article?.attributes["data-notion-page-icon"]?.trimmingSpaces(), !icon.isEmpty,
            !icon.contains(text: "/"), !icon.contains(text: ".")
        else { return nil }
        return icon
    }

    /// An image's source as a property or link: a wiki link to the attachment when it is in the export, else its URL.
    private func imageReference(_ source: String, asWikiLink: Bool) -> String {
        if let target = attachmentTarget(forHref: source) {
            return asWikiLink ? "[[\(target)]]" : target
        }
        return source
    }

    // MARK: Blocks

    private static let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "figure", "pre", "hr", "div", "details",
        "table", "nav", "section", "article", "header", "summary", "audio", "video", "iframe", "li", "aside",
    ]

    private static func isBlock(_ node: HTMLNode) -> Bool {
        guard let tag = node.tagName else { return false }
        return blockTags.contains(tag)
    }

    /// The blocks of `nodes`, with runs of inline content between blocks becoming paragraphs, and lists next to each
    /// other (Notion writes each item in its own list) joined.
    private mutating func blocks(of nodes: [HTMLNode]) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var inlineRun: [HTMLNode] = []
        // Links to pages one after the other are lines of one block, as Notion draws them: a compact list.
        var previousWasPageLink = false
        func flush(into result: inout [MarkdownBlock], reader: inout NotionPageReader) {
            guard !inlineRun.isEmpty else { return }
            let inlines = reader.inlines(of: inlineRun)
            if !MarkdownInlineNormalizer.isBlank(inlines) {
                result.append(.paragraph(inlines))
                previousWasPageLink = false
            }
            inlineRun = []
        }
        for node in nodes {
            if NotionPageReader.isBlock(node) {
                flush(into: &result, reader: &self)
                let isPageLink = node.tagName == "figure" && node.hasClass("link-to-page")
                let produced = blocks(ofElement: node)
                if isPageLink, previousWasPageLink, produced.count == 1, case .paragraph(let link) = produced[0],
                    case .paragraph(let previous)? = result.last
                {
                    result[result.count - 1] = .paragraph(previous + [.lineBreak] + link)
                } else {
                    for block in produced {
                        NotionPageReader.appendJoiningLists(block, to: &result)
                    }
                }
                if !produced.isEmpty { previousWasPageLink = isPageLink }
            } else {
                inlineRun.append(node)
            }
        }
        flush(into: &result, reader: &self)
        return result
    }

    private static func appendJoiningLists(_ block: MarkdownBlock, to blocks: inout [MarkdownBlock]) {
        switch (blocks.last, block) {
        case (.bulletList(let previous)?, .bulletList(let items)):
            blocks[blocks.count - 1] = .bulletList(previous + items)
        case (.numberedList(let start, let previous)?, .numberedList(_, let items)):
            blocks[blocks.count - 1] = .numberedList(start: start, previous + items)
        default:
            blocks.append(block)
        }
    }

    private mutating func blocks(ofElement element: HTMLNode) -> [MarkdownBlock] {
        let tag = element.tagName ?? ""
        let blockColor = element.classes.first(where: { $0.hasPrefix("block-color-") })
            .map { String($0.dropFirst("block-color-".count)) }
            .flatMap { $0 == "default" || $0 == "default_background" ? nil : $0 }
        switch tag {
        case "p", "section", "article", "header", "li":
            let content = blocks(of: element.children)
            return blockColor.map { NotionPageReader.colored(content, color: $0) } ?? content
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.dropFirst())) ?? 1
            let text = inlines(of: element.children)
            // A heading's color is its text's: a text color as that color, a background as a highlight.
            if let blockColor, !MarkdownInlineNormalizer.isBlank(text) {
                return [.heading(level: level, NotionColors.coloredBlock(text, color: blockColor))]
            }
            return [.heading(level: level, text)]
        case "aside":
            if element.hasClass("callout") || element.attributes["data-notion-callout"] != nil { return [callout(of: element)] }
            return blocks(of: element.children)
        case "ul" where element.hasClass("toggle"):
            return element.elementChildren.flatMap { item in blocks(of: item.children) }
        case "ul":
            let items = listItems(of: element)
            return [.bulletList(blockColor.map { color in NotionPageReader.colored(items, color: color) } ?? items)]
        case "ol":
            if let blockColor {
                let start = Int(element.attributes["start"] ?? "") ?? 1
                return [.numberedList(start: start, NotionPageReader.colored(listItems(of: element), color: blockColor))]
            }
            let start = Int(element.attributes["start"] ?? "") ?? 1
            return [.numberedList(start: start, listItems(of: element))]
        case "blockquote":
            let content = blockColor.map { NotionPageReader.colored(blocks(of: element.children), color: $0) } ?? blocks(of: element.children)
            return content.isEmpty ? [] : [.quote(content)]
        case "figure":
            let content = blocks(ofFigure: element)
            guard let blockColor, !element.hasClass("callout") else { return content }
            let colored = NotionPageReader.colored(content, color: blockColor)
            if colored == content { droppedBlockColorCount += 1 }
            return colored
        case "pre":
            if blockColor != nil { droppedBlockColorCount += 1 }
            return [codeBlock(of: element)]
        case "hr":
            return [.thematicBreak]
        case "details":
            let toggle = blocks(ofToggle: element)
            return blockColor.map { NotionPageReader.colored(toggle, color: $0) } ?? toggle
        case "table":
            if element.hasClass("collection-content") {
                return blocks(ofInlineDatabase: element, holder: element.parent)
            }
            return [table(of: element)]
        case "nav":
            if element.hasClass("table_of_contents") { return tableOfContents(element) }
            note(.simplified, "a navigation block (\(element.classes.joined(separator: " "))) was left out")
            return []
        case "div":
            if element.hasClass("column-list") || element.attributes["data-notion-column-list"] != nil {
                return columnLayout(element)
            }
            if element.hasClass("collection-content") {
                if let table = element.firstDescendant(where: { $0.tagName == "table" }) {
                    return blocks(ofInlineDatabase: table, holder: element)
                }
                return []
            }
            return blocks(of: element.children)
        case "summary":
            return [.paragraph(inlines(of: element.children))]
        case "audio", "video", "iframe":
            guard let source = element.attributes["src"] ?? element.firstDescendant(where: { $0.tagName == "source" })?.attributes["src"] else {
                return []
            }
            return [embedOrLink(source)]
        case "script", "style", "link", "meta":
            return []
        default:
            return blocks(of: element.children)
        }
    }

    /// Columns as a `[!multi-column]` callout, each column a `[!blank]` callout of its blocks, the layout of Modular
    /// CSS Layout that Graphite and Obsidian with that snippet draw. A column wider than the narrowest is `wide-2` to
    /// `wide-5`, its share of the width. A layout of one column is its blocks.
    private mutating func columnLayout(_ list: HTMLNode) -> [MarkdownBlock] {
        let columns = list.elementChildren.filter { $0.hasClass("column") }
        guard columns.count > 1 else { return columns.flatMap { blocks(of: $0.children) } }
        let ratios = columns.map { column -> Double in
            if let ratio = column.attributes["data-notion-column-ratio"].flatMap(Double.init), ratio > 0 { return ratio }
            return NotionPageReader.percentWidth(in: column.attributes["style"]) ?? 1
        }
        let narrowest = ratios.min() ?? 1
        let body = zip(columns, ratios).map { column, ratio -> MarkdownBlock in
            let share = max(1, min(5, Int((ratio / narrowest).rounded())))
            return .callout(type: share > 1 ? "blank|wide-\(share)" : "blank", title: [], folding: .notFoldable,
                            body: blocks(of: column.children))
        }
        return [.callout(type: "multi-column", title: [], folding: .notFoldable, body: body)]
    }

    /// The percentage a `style` gives as `width:25%`, `nil` without one.
    static func percentWidth(in style: String?) -> Double? {
        guard let style, let range = style.range(ofText: "width:") else { return nil }
        let value = style[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." || $0 == " " })
        guard style[range.upperBound...].dropFirst(value.count).first == "%" else { return nil }
        return Double(value.trimmingSpaces())
    }

    /// The width in pixels a `style` gives as `width:720px`, `nil` without one.
    static func pixelWidth(in style: String?) -> Int? {
        guard let style, let range = style.range(ofText: "width:") else { return nil }
        let value = style[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." || $0 == " " })
        guard style[range.upperBound...].dropFirst(value.count).hasPrefix("px"), let width = Double(value.trimmingSpaces()) else { return nil }
        return Int(width.rounded())
    }

    /// `blocks` in Notion's block color `color`: the text of their paragraphs and headings colored, a background as a
    /// highlight.
    static func colored(_ blocks: [MarkdownBlock], color: String) -> [MarkdownBlock] {
        blocks.map { block in
            switch block {
            case .paragraph(let inlines) where holdsText(inlines): return .paragraph(NotionColors.coloredBlock(inlines, color: color))
            case .heading(let level, let inlines) where holdsText(inlines):
                return .heading(level: level, NotionColors.coloredBlock(inlines, color: color))
            case .callout(let type, let title, let folding, let body) where holdsText(title):
                return .callout(type: type, title: NotionColors.coloredBlock(title, color: color), folding: folding, body: body)
            case .quote(let content): return .quote(colored(content, color: color))
            default: return block
            }
        }
    }

    /// `items` in the block color `color`, the blocks of each.
    static func colored(_ items: [MarkdownListItem], color: String) -> [MarkdownListItem] {
        items.map { item in
            var item = item
            item.blocks = colored(item.blocks, color: color)
            return item
        }
    }

    /// Whether inline content holds text a color can show on, not only embeds and links to files.
    private static func holdsText(_ inlines: [MarkdownInline]) -> Bool {
        !MarkdownInlineNormalizer.plainText(of: inlines.filter { inline in
            if case .wikiLink(_, _, true) = inline { return false }
            if case .image = inline { return false }
            return true
        }).trimmingSpaces().isEmpty
    }

    private mutating func listItems(of list: HTMLNode) -> [MarkdownListItem] {
        var items: [MarkdownListItem] = []
        for item in list.elementChildren where item.tagName == "li" {
            var checkbox: Bool?
            var content: [HTMLNode] = []
            for child in item.children {
                if child.tagName == "div", child.hasClass("checkbox") {
                    checkbox = child.hasClass("checkbox-on")
                } else if child.tagName == "input", child.attributes["type"] == "checkbox" {
                    checkbox = child.attributes["checked"] != nil
                } else {
                    content.append(child)
                }
            }
            if checkbox == nil, list.hasClass("to-do-list") { checkbox = false }
            let itemColor = item.classes.compactMap(NotionColors.colorName(fromClass:)).first
            let itemBlocks = blocks(of: content)
            items.append(MarkdownListItem(checkbox: checkbox, blocks: itemColor.map { NotionPageReader.colored(itemBlocks, color: $0) } ?? itemBlocks))
        }
        return items
    }

    private mutating func blocks(ofToggle details: HTMLNode) -> [MarkdownBlock] {
        let summary = details.elementChildren.first(where: { $0.tagName == "summary" })
        let content = details.children.filter { $0 !== summary }
        let title = summary.map { inlines(of: $0.children) } ?? []
        let style = summary?.attributes["style"] ?? ""
        let headingSizes = [("1.875em", 1), ("1.5em", 2), ("1.25em", 3)]
        // A toggle heading stays a heading: headings fold in Obsidian and Graphite, and links to them keep working.
        if let level = headingSizes.first(where: { style.contains(text: "font-size:\($0.0)") })?.1 {
            return [.heading(level: level, title)] + blocks(of: content)
        }
        return [.callout(type: "note", title: title, folding: .folded, body: blocks(of: content))]
    }

    private mutating func blocks(ofFigure figure: HTMLNode) -> [MarkdownBlock] {
        let caption = figure.elementChildren.first(where: { $0.tagName == "figcaption" })
        var result: [MarkdownBlock]
        if figure.hasClass("callout") {
            result = [callout(of: figure)]
        } else if figure.hasClass("equation") || figure.attributes["data-notion-equation"] != nil {
            let tex = figure.attributes["data-notion-equation"]
                ?? figure.firstDescendant(where: { $0.attributes["data-notion-equation"] != nil })?.attributes["data-notion-equation"]
                ?? figure.firstDescendant(where: { $0.tagName == "annotation" })?.textContent ?? ""
            result = [.mathBlock(tex)]
        } else if figure.hasClass("link-to-page") {
            result = linkToPage(figure)
        } else if let bookmark = figure.firstDescendant(where: { $0.tagName == "a" && $0.hasClass("bookmark") }) {
            result = self.bookmark(bookmark).map { [$0] } ?? []
        } else if figure.hasClass("image") || figure.firstDescendant(where: { $0.tagName == "img" }) != nil
            && figure.firstDescendant(where: { $0.hasClass("source") }) == nil
        {
            result = image(of: figure)
        } else if let source = figure.firstDescendant(where: { $0.hasClass("source") }) {
            if let link = source.firstDescendant(where: { $0.tagName == "a" }), let href = link.attributes["href"] {
                let alias = link.attributes["data-notion-file-alias"].flatMap { $0.isEmpty ? nil : $0 }
                if href.lowercased().hasSuffix(".html"), case .attachment(let target) = resolve(href: href) {
                    result = [.paragraph([.wikiLink(target: target, label: alias, isEmbed: false)])]
                } else {
                    result = [embedOrLink(href)]
                }
            } else {
                result = blocks(of: source.children)
            }
        } else if let media = figure.firstDescendant(where: { ["audio", "video", "iframe"].contains($0.tagName ?? "") }) {
            result = blocks(ofElement: media)
        } else {
            result = blocks(of: figure.children.filter { $0 !== caption })
        }
        if let caption {
            let inlines = inlines(of: caption.children)
            if !MarkdownInlineNormalizer.isBlank(inlines) { result.append(.paragraph(inlines)) }
        }
        return result
    }

    private mutating func callout(of figure: HTMLNode) -> MarkdownBlock {
        let parts = figure.elementChildren
        let contentHolder = parts.last
        var icon: (emoji: String?, name: String?)?
        if parts.count >= 2, let iconHolder = parts.first {
            if let emoji = NotionPageReader.emoji(in: iconHolder) ?? figure.attributes["data-notion-callout-icon"].flatMap({ $0.isEmpty ? nil : $0 }) {
                icon = (emoji, nil)
            } else if let image = iconHolder.firstDescendant(where: { $0.tagName == "img" }) {
                icon = (nil, NotionCallouts.iconName(fromSource: image.attributes["src"] ?? ""))
            } else {
                let emoji = iconHolder.textContent.trimmingSpacesAndLineBreaks()
                if !emoji.isEmpty { icon = (emoji, nil) }
            }
        }
        var content = contentHolder?.children ?? []
        // The first block of a callout is its title: a paragraph, or the text Notion writes before the first block.
        var title: [MarkdownInline] = []
        while let first = content.first, first.text?.trimmingSpacesAndLineBreaks().isEmpty == true {
            content.removeFirst()
        }
        if let first = content.first, first.tagName == "p" {
            let titleNodes = first.children.prefix(while: { !NotionPageReader.isBlock($0) })
            title = inlines(of: Array(titleNodes))
            content = Array(first.children.dropFirst(titleNodes.count)) + content.dropFirst()
        } else {
            let titleNodes = content.prefix(while: { !NotionPageReader.isBlock($0) })
            title = inlines(of: Array(titleNodes))
            content = Array(content.dropFirst(titleNodes.count))
        }
        // The callout's color is its type's where it has one (a red callout is `[!danger]`), else its icon decides.
        let background = figure.attributes["data-notion-callout-background"]
            ?? figure.classes.compactMap(NotionColors.colorName(fromClass:)).first
        let type = background.flatMap(NotionColors.calloutType(forBackground:))
            ?? NotionCallouts.calloutType(emoji: icon?.emoji, iconName: icon?.name)
        if let emoji = icon?.emoji {
            title = MarkdownInlineNormalizer.isBlank(title) ? [.text(emoji)] : [.text(emoji + " ")] + title
        }
        return .callout(type: type, title: title, folding: .notFoldable, body: blocks(of: content))
    }

    private mutating func linkToPage(_ figure: HTMLNode) -> [MarkdownBlock] {
        guard let link = figure.firstDescendant(where: { $0.tagName == "a" }), let href = link.attributes["href"] else { return [] }
        let label = textWithoutIcons(link).trimmingSpacesAndLineBreaks()
        switch resolve(href: href) {
        case .page(let target, let heading):
            return [.paragraph([wikiLink(to: target, heading: heading, label: label)])]
        default:
            return [.paragraph(inlines(of: [link]))]
        }
    }

    /// A bookmark as a link to its address with its title, and the first sentence of its description. One without an
    /// address is its title, and one with neither is left out and reported.
    private mutating func bookmark(_ bookmark: HTMLNode) -> MarkdownBlock? {
        let href = (bookmark.attributes["href"] ?? "").trimmingSpaces()
        let title = bookmark.firstDescendant(where: { $0.hasClass("bookmark-title") })?.textContent
            .trimmingSpacesAndLineBreaks() ?? ""
        guard !href.isEmpty else {
            if title.isEmpty {
                note(.leftOut, "an empty bookmark, with no address, was left out")
                return nil
            }
            return .paragraph([.text(title)])
        }
        let description = bookmark.firstDescendant(where: { $0.hasClass("bookmark-description") })?.textContent ?? ""
        var inlines: [MarkdownInline] = [.link(destination: href, label: [.text(title.isEmpty ? href : title)])]
        let sentence = NotionPageReader.firstSentence(of: description)
        if !sentence.isEmpty {
            inlines.append(.lineBreak)
            inlines.append(.text(sentence))
        }
        return .paragraph(inlines)
    }

    /// The text up to the first end of a sentence: a `.`, `?` or `!` followed by a space or the end, so that a dot
    /// inside an address or a number does not end it.
    static func firstSentence(of text: String) -> String {
        let characters = Array(text.trimmingSpacesAndLineBreaks())
        var sentence = ""
        for (index, character) in characters.enumerated() {
            if character.isNewline { break }
            sentence.append(character)
            if character == "." || character == "?" || character == "!",
                index + 1 == characters.count || characters[index + 1].isWhitespace
            {
                break
            }
        }
        return sentence
    }

    private mutating func image(of figure: HTMLNode) -> [MarkdownBlock] {
        guard let image = figure.firstDescendant(where: { $0.tagName == "img" }), let source = image.attributes["src"] else {
            return []
        }
        let link = figure.firstDescendant(where: { $0.tagName == "a" })?.attributes["href"]
        if let target = holdFile(source) ?? attachmentTarget(forHref: source) ?? link.flatMap({ attachmentTarget(forHref: $0) }) {
            // The width Notion shows the picture at, as Obsidian's `![[x.png|720]]`.
            let width = NotionPageReader.pixelWidth(in: image.attributes["style"]).map { String($0) }
            return [.paragraph([.wikiLink(target: target, label: width, isEmbed: true)])]
        }
        if let mark = missingPicture(source) { return [.paragraph([mark])] }
        return [.paragraph([.image(source: source, alternativeText: image.attributes["alt"] ?? "")])]
    }

    /// What stands for a picture the page shows from a file of the export that the export does not hold, with a
    /// finding: an embed of it would show nothing, and a Markdown image pointing at it would be a link to nothing, so
    /// an italic mark with its name takes its place, which does not read as the page's own text. A picture from the web
    /// or held inside the page is not missing: `nil`.
    private mutating func missingPicture(_ source: String) -> MarkdownInline? {
        guard !source.lowercased().hasPrefix("data:"), case .unresolved(let name) = resolve(href: source) else { return nil }
        note(.leftOut, "a picture, \(name), which the export does not hold, was marked in its place")
        return .emphasis([.text("(picture not in the export: \(name))")])
    }

    /// The wiki link target standing for a file the page holds inside itself (`href` a `data:` address), which the
    /// importer writes beside the note; `nil` for any other address.
    private mutating func holdFile(_ href: String) -> String? {
        guard href.lowercased().hasPrefix("data:") else { return nil }
        guard let (mediaType, bytes) = NotionHeldFile.decode(dataAddress: href) else {
            note(.leftOut, "a file held inside the page could not be read, so it was left out")
            return nil
        }
        let number = heldFiles.count + 1
        let stem = mediaType.hasPrefix("image/") ? "Picture" : "File"
        let file = NotionHeldFile(placeholder: NotionHeldFile.placeholderPrefix + String(number),
                                  name: "\(stem) \(number).\(NotionHeldFile.pathExtension(ofMediaType: mediaType))", bytes: bytes)
        heldFiles.append(file)
        return file.placeholder
    }

    private mutating func embedOrLink(_ href: String) -> MarkdownBlock {
        if let target = holdFile(href) { return .paragraph([.wikiLink(target: target, label: nil, isEmbed: true)]) }
        switch resolve(href: href) {
        case .attachment(let target):
            return .paragraph([.wikiLink(target: target, label: nil, isEmbed: true)])
        case .page(let target, let heading):
            return .paragraph([wikiLink(to: target, heading: heading, label: nil)])
        case .heading(let text):
            return .paragraph([.wikiLink(target: "#" + text, label: nil, isEmbed: false)])
        case .external(let url):
            return .paragraph([.link(destination: url, label: [.text(url)])])
        case .unresolved(let text):
            note(.leftOut, "a link to \(text), which the export does not hold, was kept as text")
            return .paragraph([.text(text)])
        }
    }

    private func codeBlock(of pre: HTMLNode) -> MarkdownBlock {
        let code = pre.firstDescendant(where: { $0.tagName == "code" }) ?? pre
        let classAttribute = code.attributes["class"] ?? ""
        var language = ""
        if let range = classAttribute.range(ofText: "language-") {
            language = NotionCallouts.codeLanguage(String(classAttribute[range.upperBound...]))
        }
        return .codeBlock(language: language, code: code.textContent)
    }

    private mutating func table(of table: HTMLNode) -> MarkdownBlock {
        let rows = table.descendants(where: { $0.tagName == "tr" })
        var cells = rows.map { row in
            row.elementChildren.filter { $0.tagName == "td" || $0.tagName == "th" }.map { cell in
                inlines(of: cell.children)
            }
        }
        guard !cells.isEmpty else { return .table(header: [], rows: []) }
        let header = cells.removeFirst()
        return .table(header: header, rows: cells)
    }

    private mutating func blocks(ofInlineDatabase table: HTMLNode, holder: HTMLNode?) -> [MarkdownBlock] {
        let identifier = holder?.attributes["id"].flatMap(NotionPageReader.hyphenatedIdentifier)
        if let identifier, let base = resolver.target(ofPage: identifier)?.embeddedBase {
            if inlineDatabases[identifier] == nil { inlineDatabases[identifier] = readDatabaseTable(table) }
            return [.paragraph([.wikiLink(target: base, label: nil, isEmbed: true)])]
        }
        // Else the database whose folder holds the rows the table links to.
        if let href = table.firstDescendant(where: { $0.hasClass("cell-title") })?
            .firstDescendant(where: { $0.tagName == "a" })?.attributes["href"]
        {
            let rowPath = resolvedComponents(percentDecoded(href))
            if rowPath.count >= 2, let folder = rowPath.dropLast().last {
                let databasePath = Array(rowPath.dropLast(2)) + [folder + ".html"]
                if let databaseIdentifier = resolver.pageIdentifier(atExportPath: databasePath),
                    let base = resolver.target(ofPage: databaseIdentifier)?.embeddedBase
                {
                    return [.paragraph([.wikiLink(target: base, label: nil, isEmbed: true)])]
                }
            }
        }
        let name = holder?.firstDescendant(where: { $0.hasClass("collection-title") })?.textContent
            .trimmingSpacesAndLineBreaks() ?? ""
        // A linked view whose filter shows no row names its database by its title alone.
        if !name.isEmpty, let base = resolver.database(titled: name)?.embeddedBase {
            note(.simplified, "the view “\(name)” of a database shows the database's base, without the view's own filter, which the export does not give")
            return [.paragraph([.wikiLink(target: base, label: nil, isEmbed: true)])]
        }
        note(.simplified, "the database \(name.isEmpty ? "without a title" : "“\(name)”") is not in the export, so its table was written as a Markdown table")
        var result: [MarkdownBlock] = []
        if !name.isEmpty { result.append(.paragraph([.strong([.text(name)])])) }
        result.append(databaseTable(table))
        return result
    }

    /// A database's table as a Markdown table: its columns and the text of each cell.
    private mutating func databaseTable(_ table: HTMLNode) -> MarkdownBlock {
        let headerCells = table.descendants(where: { $0.tagName == "th" }).map { [MarkdownInline.text(textWithoutIcons($0).trimmingSpacesAndLineBreaks())] }
        let rows = table.descendants(where: { $0.tagName == "tr" && $0.parent?.tagName == "tbody" }).map { row in
            row.elementChildren.filter { $0.tagName == "td" }.map { cell in databaseCell(cell) }
        }
        return .table(header: headerCells, rows: rows)
    }

    private mutating func databaseCell(_ cell: HTMLNode) -> [MarkdownInline] {
        if let checkbox = cell.firstDescendant(where: { $0.hasClass("checkbox") }) {
            return [.text(checkbox.hasClass("checkbox-on") ? "✓" : "")]
        }
        let values = cell.descendants(where: { $0.hasClass("selected-value") })
        if !values.isEmpty {
            return [.text(values.map { $0.textContent.trimmingSpacesAndLineBreaks() }.joined(separator: ", "))]
        }
        return inlines(of: cell.children)
    }

    private func readDatabaseTable(_ table: HTMLNode) -> NotionDatabaseTable {
        let headerCells = table.descendants(where: { $0.tagName == "th" })
        let columns = headerCells.map { cell -> NotionDatabaseTable.Column in
            let typeClass = cell.firstDescendant(where: { $0.tagName == "svg" })?.classes.first(where: { $0.hasPrefix("types") })
            // Since 2025 the column's type is the name of its icon's picture (`…/icons/calendar_gray.svg`).
            let iconType = cell.firstDescendant(where: { $0.tagName == "img" })?.attributes["src"]
                .flatMap(NotionPropertyReader.notionType(ofIconAddress:))
            return NotionDatabaseTable.Column(name: textWithoutIcons(cell).trimmingSpacesAndLineBreaks(),
                                              notionType: typeClass.map(NotionPropertyReader.notionType(ofIconClass:)) ?? iconType,
                                              isTitle: typeClass == "typesTitle" || iconType == "title")
        }
        let widths = table.firstDescendant(where: { $0.tagName == "colgroup" })?.elementChildren
            .filter { $0.tagName == "col" }.map { NotionPageReader.percentWidth(in: $0.attributes["style"]) } ?? []
        var identifiers: [String] = []
        var titles: [String] = []
        for row in table.descendants(where: { $0.tagName == "tr" && $0.parent?.tagName == "tbody" }) {
            let titleCell = row.elementChildren.first(where: { $0.hasClass("cell-title") })
            let link = titleCell?.firstDescendant(where: { $0.tagName == "a" })
            let fromLink = link?.attributes["href"].flatMap { href in
                NotionExportEntryName(percentDecoded(href).split(separator: "/").last.map(String.init) ?? "")?.pageIdentifier
            }
            if let identifier = fromLink ?? row.attributes["id"].flatMap(NotionPageReader.hyphenatedIdentifier) {
                identifiers.append(identifier)
                titles.append(titleCell.map { textWithoutIcons($0).trimmingSpacesAndLineBreaks() } ?? "")
            }
        }
        var tableColumns = columns
        if !tableColumns.contains(where: { $0.isTitle }),
            let titleIndex = table.descendants(where: { $0.tagName == "tr" && $0.parent?.tagName == "tbody" }).first?
                .elementChildren.firstIndex(where: { $0.hasClass("cell-title") }), titleIndex < tableColumns.count
        {
            tableColumns[titleIndex].isTitle = true
        }
        return NotionDatabaseTable(columns: tableColumns, rowPageIdentifiers: identifiers, rowTitles: titles,
                                   columnWidths: widths.count == tableColumns.count ? widths : [])
    }

    private mutating func tableOfContents(_ navigation: HTMLNode) -> [MarkdownBlock] {
        var entries: [(level: Int, item: MarkdownListItem)] = []
        for item in navigation.elementChildren {
            let level = item.classes.compactMap { name -> Int? in
                guard name.hasPrefix("table_of_contents-indent-") else { return nil }
                return Int(name.dropFirst("table_of_contents-indent-".count))
            }.first ?? 0
            let text = item.textContent.trimmingSpacesAndLineBreaks()
            guard !text.isEmpty else { continue }
            let link = MarkdownInline.wikiLink(target: "#" + NotionPageReader.headingLinkText(text), label: nil, isEmbed: false)
            entries.append((level, MarkdownListItem(blocks: [.paragraph([link])])))
        }
        func nest(_ slice: ArraySlice<(level: Int, item: MarkdownListItem)>) -> [MarkdownListItem] {
            var items: [MarkdownListItem] = []
            var index = slice.startIndex
            while index < slice.endIndex {
                let level = slice[index].level
                var item = slice[index].item
                var end = index + 1
                while end < slice.endIndex, slice[end].level > level { end += 1 }
                let children = nest(slice[(index + 1)..<end])
                if !children.isEmpty { item.blocks.append(.bulletList(children)) }
                items.append(item)
                index = end
            }
            return items
        }
        let items = nest(entries[...])
        return items.isEmpty ? [] : [.bulletList(items)]
    }

    /// A heading's text as a link to it: Obsidian's links cannot hold `#`, `|`, `^`, `[` or `]`.
    static func headingLinkText(_ text: String) -> String {
        let replaced = text.map { "#|^[]".contains($0) ? " " : String($0) }.joined()
        return replaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: Inline content

    private static let formattingTags: Set<String> = ["strong", "b", "em", "i", "mark", "del", "s", "strike", "u"]

    private mutating func inlines(of nodes: [HTMLNode]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for (index, node) in nodes.enumerated() {
            if let text = node.text {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for (lineIndex, line) in lines.enumerated() {
                    if lineIndex > 0 { result.append(.lineBreak) }
                    if !line.isEmpty { result.append(.text(String(line))) }
                }
                continue
            }
            guard let tag = node.tagName else { continue }
            switch tag {
            case "br":
                // Notion writes a line break before a change of style right after a line break: the first is dropped.
                if let nextTag = NotionPageReader.nodeAfter(node, in: nodes, at: index)?.tagName,
                    NotionPageReader.formattingTags.contains(nextTag)
                {
                    continue
                }
                result.append(.lineBreak)
            case "strong", "b":
                result.append(.strong(inlines(of: node.children)))
            case "em", "i":
                result.append(.emphasis(inlines(of: node.children)))
            case "del", "s", "strike":
                result.append(.strikethrough(inlines(of: node.children)))
            case "u":
                result.append(.underline(inlines(of: node.children)))
            case "mark":
                let color = node.classes.compactMap(NotionColors.colorName(fromClass:)).first
                    ?? node.attributes["data-notion-highlight"].flatMap { $0 == "default" ? nil : $0 }
                let children = inlines(of: node.children)
                result.append(contentsOf: color.map { NotionColors.colored(children, color: $0) } ?? children)
            case "code":
                result.append(.code(node.textContent))
            case "a":
                result.append(contentsOf: link(node))
            case "time":
                result.append(.text(node.textContent.replacingEvery("@", with: "")))
            case "img":
                if node.hasClass("icon") { continue }
                if let source = node.attributes["src"] {
                    if let target = holdFile(source) ?? attachmentTarget(forHref: source) {
                        result.append(.wikiLink(target: target, label: nil, isEmbed: true))
                    } else if let mark = missingPicture(source) {
                        result.append(mark)
                    } else {
                        result.append(.image(source: source, alternativeText: node.attributes["alt"] ?? ""))
                    }
                }
            case "span":
                if node.hasClass("notion-text-equation-token") || node.attributes["data-notion-inline-equation"] != nil {
                    result.append(.math(node.attributes["data-notion-inline-equation"]
                        ?? node.firstDescendant(where: { $0.tagName == "annotation" })?.textContent ?? ""))
                } else if node.hasClass("icon") {
                    continue
                } else if (node.attributes["style"] ?? "").contains(text: "border-bottom:0.05em solid") {
                    result.append(.underline(inlines(of: node.children)))
                } else {
                    result.append(contentsOf: inlines(of: node.children))
                }
            case "svg", "script", "style", "link", "meta":
                continue
            case "math":
                if let annotation = node.firstDescendant(where: { $0.tagName == "annotation" }) {
                    result.append(.math(annotation.textContent))
                }
            default:
                if NotionPageReader.isBlock(node) {
                    // A block inside inline content: its text, on its own line.
                    result.append(.lineBreak)
                    result.append(.text(node.textContent))
                } else {
                    result.append(contentsOf: inlines(of: node.children))
                }
            }
        }
        return result
    }

    /// The node after `node` in reading order: its next sibling, or the next sibling of the style it ends.
    private static func nodeAfter(_ node: HTMLNode, in nodes: [HTMLNode], at index: Int) -> HTMLNode? {
        if index + 1 < nodes.count { return nodes[index + 1] }
        var current = node
        while let parent = current.parent, let tag = parent.tagName, formattingTags.contains(tag) {
            if let position = parent.parent?.children.firstIndex(where: { $0 === parent }),
                let siblings = parent.parent?.children, position + 1 < siblings.count
            {
                return siblings[position + 1]
            }
            current = parent
        }
        return nil
    }

    private mutating func link(_ anchor: HTMLNode) -> [MarkdownInline] {
        let label = inlines(of: anchor.children)
        let labelText = MarkdownInlineNormalizer.plainText(of: label).trimmingSpacesAndLineBreaks()
        guard let href = anchor.attributes["href"], !href.isEmpty else { return label }
        if let target = holdFile(href) { return [.wikiLink(target: target, label: labelText, isEmbed: false)] }
        let resolution = resolve(href: href)
        switch resolution {
        case .page, .attachment, .heading:
            if NotionPageReader.holdsCode(label) {
                note(.simplified, "the code style of a link's text was dropped: the text of a wiki link holds no style")
            }
        default:
            break
        }
        switch resolution {
        case .page(let target, var heading):
            // A link whose text is a Notion address shows the page's name instead, and the heading the address points
            // at, which Notion leaves out of the link itself.
            let labelAddress = NotionPageReader.notionAddressIdentifiers(labelText)
            if heading == nil, let labelAddress, resolver.target(ofPage: labelAddress.page) == target {
                heading = self.heading(inPage: labelAddress.page, block: labelAddress.block)
            }
            let shownLabel = labelAddress != nil || labelText.hasPrefix("http") ? nil : labelText
            return [wikiLink(to: target, heading: heading, label: shownLabel)]
        case .attachment(let target):
            return [.wikiLink(target: target, label: labelText, isEmbed: false)]
        case .heading(let text):
            return [.wikiLink(target: "#" + text, label: labelText == text ? nil : labelText, isEmbed: false)]
        case .external(let url):
            return [.link(destination: url, label: label)]
        case .unresolved:
            note(.leftOut, "a link to a page or file the export does not hold (\(labelText)) was kept as text")
            return label
        }
    }

    private static func holdsCode(_ inlines: [MarkdownInline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case .code: return true
            case .strong(let children), .emphasis(let children), .strikethrough(let children), .highlight(let children),
                .underline(let children), .textColor(_, let children), .backgroundColor(_, let children):
                return holdsCode(children)
            default: return false
            }
        }
    }

    private func wikiLink(to target: NotionLinkTarget, heading: String?, label: String?) -> MarkdownInline {
        var linkTarget = target.linkTarget
        if let heading { linkTarget += "#" + heading }
        let shown = label.flatMap { $0.isEmpty ? nil : $0 } ?? (target.linkTarget == target.title ? nil : target.title)
        let wikiLabel = shown == linkTarget || (heading == nil && shown == target.linkTarget) ? nil : shown
        return .wikiLink(target: linkTarget, label: wikiLabel, isEmbed: false)
    }

    private func textWithoutIcons(_ node: HTMLNode) -> String {
        var result = ""
        for child in node.children {
            if let text = child.text {
                result += text
            } else if !(child.hasClass("icon") || child.tagName == "svg" || child.tagName == "img" || child.tagName == "style") {
                result += textWithoutIcons(child)
            }
        }
        return result
    }

    // MARK: Links

    private enum LinkResolution {
        case page(NotionLinkTarget, heading: String?)
        case attachment(String)
        case heading(String)
        case external(String)
        case unresolved(String)
    }

    private func resolve(href: String) -> LinkResolution {
        if href.hasPrefix("#") {
            let identifier = NotionPageReader.hyphenatedIdentifier(String(href.dropFirst()))
            if let identifier, let text = headingTextByBlock[identifier] {
                return .heading(NotionPageReader.headingLinkText(text))
            }
            return .unresolved(href)
        }
        let lowered = href.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            if let (pageIdentifier, blockIdentifier) = NotionPageReader.notionAddressIdentifiers(href),
                let target = resolver.target(ofPage: pageIdentifier)
            {
                return .page(target, heading: heading(inPage: pageIdentifier, block: blockIdentifier))
            }
            // A page of the export published elsewhere (`https://site.github.io/people/Name-<32 digits>`) is the page.
            if let address = WebAddress(href),
                let identifier = NotionPageReader.trailingIdentifier(of: address.path.split(separator: "/").last.map(String.init) ?? ""),
                let target = resolver.target(ofPage: identifier)
            {
                return .page(target, heading: nil)
            }
            return .external(href)
        }
        if lowered.hasPrefix("data:") {
            return .unresolved("an image held inside the page")
        }
        if lowered.hasPrefix("mailto:") || lowered.hasPrefix("tel:") || href.contains(text: "://") {
            return .external(href)
        }
        // A phone number or an e-mail address of a property, which Notion links as written.
        if let number = NotionPageReader.phoneNumber(href) { return .external("tel:" + number) }
        if NotionPageReader.isEmailAddress(href) { return .external("mailto:" + href.trimmingSpaces()) }
        // A `#` is a fragment only when no folder follows it: a folder's name may hold one (`Meeting #11/a.png`).
        let fragmentSplit = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let withoutFragment = fragmentSplit.count > 1 && fragmentSplit[1].contains("/") ? [Substring(href)] : fragmentSplit
        let path = percentDecoded(String(withoutFragment[0]))
        let fragment = withoutFragment.count > 1 ? String(withoutFragment[1]) : nil
        let components = resolvedComponents(path)
        if let last = components.last, last.lowercased().hasSuffix(".html") {
            let name = NotionExportEntryName(last)
            // The page by the identifier of its name, by its path, or by the identifier its name ends with in an
            // export whose files were renamed (`William-Dixon-<32 digits>.html`).
            let candidates = [name?.pageIdentifier, resolver.pageIdentifier(atExportPath: components),
                              NotionPageReader.trailingIdentifier(of: String(last.dropLast(".html".count)))]
            for case let identifier? in candidates {
                guard let target = resolver.target(ofPage: identifier) else { continue }
                let blockIdentifier = fragment.flatMap(NotionPageReader.hyphenatedIdentifier)
                return .page(target, heading: blockIdentifier.flatMap { heading(inPage: identifier, block: $0) })
            }
            if let target = resolver.attachmentTarget(atExportPath: components) { return .attachment(target) }
            return .unresolved(name?.title ?? String(last.dropLast(".html".count)))
        }
        if let target = resolver.attachmentTarget(atExportPath: components) {
            return .attachment(target)
        }
        return .unresolved(components.last ?? href)
    }

    private func heading(inPage page: String, block: String?) -> String? {
        guard let block else { return nil }
        if page == pageIdentifier, let text = headingTextByBlock[block] {
            return NotionPageReader.headingLinkText(text)
        }
        return resolver.headingText(inPage: page, block: block).map(NotionPageReader.headingLinkText)
    }

    private func attachmentTarget(forHref href: String) -> String? {
        if case .attachment(let target) = resolve(href: href) { return target }
        return nil
    }

    /// The export path a relative link names, from the folder of this page.
    private func resolvedComponents(_ path: String) -> [String] {
        var components = exportFolder
        for name in path.split(separator: "/", omittingEmptySubsequences: true) {
            if name == "." { continue }
            if name == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(String(name))
        }
        return components
    }

    private func percentDecoded(_ text: String) -> String {
        text.percentDecoded ?? text
    }

    /// The page and block identifiers of a Notion address: `https://www.notion.so/Title-<32 digits>?pvs=4#<32 digits>`.
    static func notionAddressIdentifiers(_ address: String) -> (page: String, block: String?)? {
        guard let address = WebAddress(address), case let host = address.host.lowercased(),
            host == "notion.so" || host.hasSuffix(".notion.so") || host.hasSuffix(".notion.site")
        else { return nil }
        let last = address.path.split(separator: "/").last.map(String.init) ?? ""
        let digits = String(last.suffix(32))
        guard let page = hyphenatedIdentifier(digits) else { return nil }
        return (page, address.fragment.flatMap(hyphenatedIdentifier))
    }

    /// The number a phone number written as text dials (`+41 79 123 45 67` gives `+41791234567`), `nil` for text that
    /// is no phone number.
    static func phoneNumber(_ text: String) -> String? {
        let trimmed = text.trimmingSpaces()
        guard let first = trimmed.first, first == "+" || first.isNumber,
            trimmed.allSatisfy({ $0.isNumber || " +()-./".contains($0) })
        else { return nil }
        let dialed = trimmed.filter { $0.isNumber || $0 == "+" }
        return dialed.filter({ $0.isNumber }).count >= 6 ? dialed : nil
    }

    /// Whether `text` is an e-mail address written as text: one `@`, a dot after it, no space or slash.
    static func isEmailAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingSpaces()
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasSuffix(".") else { return false }
        return !trimmed.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" })
    }

    /// The page identifier a name ends with, after a `-` or a space, or that the name is: 32 hexadecimal digits.
    static func trailingIdentifier(of name: String) -> String? {
        let digits = String(name.suffix(32))
        guard digits.count == 32, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        let before = name.dropLast(32).last
        guard before == nil || before == "-" || before == " " else { return nil }
        return hyphenatedIdentifier(digits)
    }

    /// An identifier written with or without hyphens, as Notion's API writes it: lowercase, hyphenated.
    static func hyphenatedIdentifier(_ text: String) -> String? {
        let digits = text.lowercased().filter { $0 != "-" }
        guard digits.count == 32, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return NotionExportEntryName("x \(digits)")?.pageIdentifier
    }

    // MARK: Properties

    private mutating func readProperty(_ row: HTMLNode) -> [NotionPropertyReader.Property] {
        guard let name = row.elementChildren.first(where: { $0.tagName == "th" }).map({ textWithoutIcons($0) })?
            .trimmingSpacesAndLineBreaks(), !name.isEmpty,
            let cell = row.elementChildren.first(where: { $0.tagName == "td" })
        else { return [] }
        let notionType = row.classes.first(where: { $0.hasPrefix("property-row-") })
            .map { String($0.dropFirst("property-row-".count)) } ?? "text"
        let links = cell.descendants(where: { $0.tagName == "a" }).map { anchor -> String in
            let href = anchor.attributes["href"] ?? ""
            switch resolve(href: href) {
            case .page(let target, _):
                return "[[\(target.linkTarget)\(target.linkTarget == target.title ? "" : "|" + target.title)]]"
            case .attachment(let target):
                return "[[\(target)]]"
            case .external(let url):
                return url
            case .heading, .unresolved:
                return anchor.textContent.trimmingSpacesAndLineBreaks()
            }
        }
        var reader = NotionPropertyReader(dateParser: dateParser)
        let property = reader.read(name: name, notionType: notionType, cell: cell, links: links)
        if let warning = reader.warning { note(.simplified, warning) }
        guard let property else { return [] }
        if let end = reader.rangeEnd {
            note(.simplified, NotionPropertyReader.rangeMessage(property: name))
            return [property, end]
        }
        return [property]
    }
}

/// Callout types and code languages from what Notion's export names.
enum NotionCallouts {
    /// The callout type for a callout's emoji or Notion icon: tips for a light bulb, warnings for a warning sign and
    /// so on, `note` for the rest.
    static func calloutType(emoji: String?, iconName: String?) -> String {
        if let emoji {
            let base = emoji.unicodeScalars.filter { $0 != "\u{FE0F}" }.map(String.init).joined()
            if let type = emojiTypes[base] { return type }
        }
        if let iconName {
            for (fragment, type) in iconTypes where iconName.contains(text: fragment) { return type }
        }
        return "note"
    }

    /// The name of a Notion icon from its address: `https://www.notion.so/icons/info-alternate_green.svg` gives
    /// `info-alternate`.
    static func iconName(fromSource source: String) -> String? {
        guard source.contains(text: "notion.so/icons/") else { return nil }
        let file = source.split(separator: "/").last.map(String.init) ?? ""
        let stem = file.split(separator: ".").first.map(String.init) ?? file
        return stem.split(separator: "_").first.map(String.init)
    }

    private static let emojiTypes: [String: String] = [
        "💡": "tip", "⚠": "warning", "🚧": "warning", "❗": "important", "‼": "important", "❕": "important",
        "📢": "important", "ℹ": "info", "📘": "info", "❓": "question", "❔": "question", "🤔": "question",
        "✅": "success", "✔": "success", "☑": "success", "❌": "failure", "✖": "failure", "⛔": "danger",
        "🚫": "danger", "🔥": "danger", "🐛": "bug", "🐞": "bug", "📝": "note", "✏": "note", "🖊": "note",
        "📌": "note", "💬": "quote", "📋": "abstract", "🧪": "example", "📎": "note",
    ]

    private static let iconTypes: [(String, String)] = [
        ("info", "info"), ("warning", "warning"), ("alert", "warning"), ("error", "danger"), ("lightbulb", "tip"),
        ("checkmark", "success"), ("check", "success"), ("question", "question"), ("bug", "bug"), ("close", "failure"),
        ("clear", "failure"), ("quote", "quote"),
    ]

    /// A code block's language, from Notion's name for it (`Python`, `Plain Text`, `C++`) to the name Obsidian's
    /// highlighter knows (`python`, none, `cpp`).
    static func codeLanguage(_ notionName: String) -> String {
        let name = notionName.trimmingSpaces().lowercased()
        let names: [String: String] = [
            "plain text": "", "plain": "", "c++": "cpp", "c#": "csharp", "f#": "fsharp", "objective-c": "objectivec",
            "visual basic": "vb", "shell": "shell", "bash": "bash", "latex": "latex", "mermaid": "mermaid",
            "markdown": "markdown", "javascript": "javascript", "typescript": "typescript", "java/c/c++/c#": "java",
            "vb.net": "vbnet", "webassembly": "wasm", "docker": "docker", "makefile": "makefile",
        ]
        if let mapped = names[name] { return mapped }
        return name.replacingEvery(" ", with: "")
    }
}
