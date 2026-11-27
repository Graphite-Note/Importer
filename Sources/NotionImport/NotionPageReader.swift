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
 * Version: 0.2
 * Date: 27/11/2026
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

    public init(linkTarget: String, title: String, isBase: Bool) {
        self.linkTarget = linkTarget
        self.title = title
        self.isBase = isBase
    }
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
}

/// One page of Notion's HTML export, read.
public struct NotionPage: Sendable {
    /// The page's identifier (hyphenated, lowercase), from its `article` element.
    public var identifier: String?
    /// The page's title, whole (the file name's copy is shortened).
    public var title: String
    /// The page's properties, with its icon and cover.
    public var frontMatter: FrontMatter
    /// The type of each property, for the vault's property types.
    public var propertyTypes: [(name: String, type: PropertyType)]
    /// The page's content.
    public var blocks: [MarkdownBlock]
    /// The database table, when the page is a database's page.
    public var database: NotionDatabaseTable?
    /// What was simplified or left out while reading.
    public var findings: [NotionPageFinding]
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
    private var flattenedColumnLayoutCount = 0

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
                guard let property = readProperty(row) else { continue }
                frontMatter.set(property.name, to: property.value)
                propertyTypes.append((property.name, property.type))
            }
        }
        if let header = document.firstElement(where: { $0.tagName == "header" }) {
            if frontMatter["icon"] == nil, let icon = readIcon(in: header) {
                frontMatter.set("icon", to: .text(icon))
                propertyTypes.append(("icon", .text))
            }
            if frontMatter["cover"] == nil,
                let cover = header.firstDescendant(where: { $0.hasClass("page-cover-image") })?.attributes["src"]
            {
                frontMatter.set("cover", to: .text(imageReference(cover, asWikiLink: true)))
                propertyTypes.append(("cover", .text))
            }
        }

        var blocks: [MarkdownBlock] = []
        if let description = document.firstElement(where: { $0.hasClass("page-description") }) {
            let inlines = inlines(of: description.children)
            if !MarkdownInlineNormalizer.isBlank(inlines) { blocks.append(.paragraph(inlines)) }
        }
        var database: NotionDatabaseTable?
        if let body {
            if let table = body.elementChildren.first, table.tagName == "table", table.hasClass("collection-content") {
                database = readDatabaseTable(table)
                blocks.append(contentsOf: self.blocks(of: Array(body.elementChildren.dropFirst())))
            } else {
                blocks.append(contentsOf: self.blocks(of: body.children))
            }
        }
        if flattenedColumnLayoutCount > 0 {
            note(.simplified, flattenedColumnLayoutCount == 1
                ? "a layout in columns was flattened into one column, the columns one after the other"
                : "\(flattenedColumnLayoutCount) layouts in columns were flattened into one column, the columns one after the other")
        }
        return NotionPage(identifier: pageIdentifier, title: title, frontMatter: frontMatter, propertyTypes: propertyTypes,
                          blocks: blocks, database: database, findings: findings)
    }

    private mutating func note(_ severity: ImportReport.Severity, _ message: String) {
        let finding = NotionPageFinding(severity: severity, message: message)
        if !findings.contains(finding) { findings.append(finding) }
    }

    // MARK: Header

    private func readIcon(in header: HTMLNode) -> String? {
        guard let holder = header.firstDescendant(where: { $0.hasClass("page-header-icon") }) else { return nil }
        if let image = holder.firstDescendant(where: { $0.tagName == "img" }), let source = image.attributes["src"] {
            return imageReference(source, asWikiLink: true)
        }
        let text = holder.textContent.trimmingSpacesAndLineBreaks()
        return text.isEmpty ? nil : text
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
        "table", "nav", "section", "article", "header", "summary", "audio", "video", "iframe", "li",
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
        func flush(into result: inout [MarkdownBlock], reader: inout NotionPageReader) {
            guard !inlineRun.isEmpty else { return }
            let inlines = reader.inlines(of: inlineRun)
            if !MarkdownInlineNormalizer.isBlank(inlines) { result.append(.paragraph(inlines)) }
            inlineRun = []
        }
        for node in nodes {
            if NotionPageReader.isBlock(node) {
                flush(into: &result, reader: &self)
                for block in blocks(ofElement: node) {
                    NotionPageReader.appendJoiningLists(block, to: &result)
                }
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
        switch tag {
        case "p", "section", "article", "header", "li":
            return blocks(of: element.children)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.dropFirst())) ?? 1
            return [.heading(level: level, inlines(of: element.children))]
        case "ul" where element.hasClass("toggle"):
            return element.elementChildren.flatMap { item in blocks(of: item.children) }
        case "ul":
            return [.bulletList(listItems(of: element))]
        case "ol":
            let start = Int(element.attributes["start"] ?? "") ?? 1
            return [.numberedList(start: start, listItems(of: element))]
        case "blockquote":
            let content = blocks(of: element.children)
            return content.isEmpty ? [] : [.quote(content)]
        case "figure":
            return blocks(ofFigure: element)
        case "pre":
            return [codeBlock(of: element)]
        case "hr":
            return [.thematicBreak]
        case "details":
            return blocks(ofToggle: element)
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
            if element.hasClass("column-list") {
                let columns = element.elementChildren.filter { $0.hasClass("column") }
                flattenedColumnLayoutCount += 1
                return columns.flatMap { blocks(of: $0.children) }
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
            items.append(MarkdownListItem(checkbox: checkbox, blocks: blocks(of: content)))
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
        } else if figure.hasClass("equation") {
            let tex = figure.firstDescendant(where: { $0.tagName == "annotation" })?.textContent ?? ""
            result = [.mathBlock(tex)]
        } else if figure.hasClass("link-to-page") {
            result = linkToPage(figure)
        } else if let bookmark = figure.firstDescendant(where: { $0.tagName == "a" && $0.hasClass("bookmark") }) {
            result = [self.bookmark(bookmark)]
        } else if figure.hasClass("image") || figure.firstDescendant(where: { $0.tagName == "img" }) != nil
            && figure.firstDescendant(where: { $0.hasClass("source") }) == nil
        {
            result = image(of: figure)
        } else if let source = figure.firstDescendant(where: { $0.hasClass("source") }) {
            if let link = source.firstDescendant(where: { $0.tagName == "a" }), let href = link.attributes["href"] {
                result = [embedOrLink(href)]
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
            if let image = iconHolder.firstDescendant(where: { $0.tagName == "img" }) {
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
        let type = NotionCallouts.calloutType(emoji: icon?.emoji, iconName: icon?.name)
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

    private mutating func bookmark(_ bookmark: HTMLNode) -> MarkdownBlock {
        let href = bookmark.attributes["href"] ?? ""
        let title = bookmark.firstDescendant(where: { $0.hasClass("bookmark-title") })?.textContent
            .trimmingSpacesAndLineBreaks() ?? ""
        let description = bookmark.firstDescendant(where: { $0.hasClass("bookmark-description") })?.textContent ?? ""
        var inlines: [MarkdownInline] = [.link(destination: href, label: [.text(title.isEmpty ? href : title)])]
        let sentence = NotionPageReader.firstSentence(of: description)
        if !sentence.isEmpty {
            inlines.append(.lineBreak)
            inlines.append(.text(sentence))
        }
        return .paragraph(inlines)
    }

    private static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingSpacesAndLineBreaks()
        var sentence = ""
        for character in trimmed {
            if character.isNewline { break }
            sentence.append(character)
            if character == "." || character == "?" || character == "!" { break }
        }
        return sentence
    }

    private mutating func image(of figure: HTMLNode) -> [MarkdownBlock] {
        guard let image = figure.firstDescendant(where: { $0.tagName == "img" }), let source = image.attributes["src"] else {
            return []
        }
        let link = figure.firstDescendant(where: { $0.tagName == "a" })?.attributes["href"]
        if let target = attachmentTarget(forHref: source) ?? link.flatMap({ attachmentTarget(forHref: $0) }) {
            return [.paragraph([.wikiLink(target: target, label: nil, isEmbed: true)])]
        }
        if let name = missingPicture(source) { return [.paragraph([.text(name)])] }
        return [.paragraph([.image(source: source, alternativeText: image.attributes["alt"] ?? "")])]
    }

    /// The name of a picture the page shows from a file of the export that the export does not hold, with a finding.
    /// An embed of it would show nothing, and a Markdown image pointing at it would be a link to nothing, so its name is
    /// kept as text. A picture from the web or held inside the page is not missing: `nil`.
    private mutating func missingPicture(_ source: String) -> String? {
        guard !source.lowercased().hasPrefix("data:"), case .unresolved(let name) = resolve(href: source) else { return nil }
        note(.leftOut, "a picture, \(name), which the export does not hold, was kept as its name")
        return name
    }

    private mutating func embedOrLink(_ href: String) -> MarkdownBlock {
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
        if let identifier, let target = resolver.target(ofPage: identifier), target.isBase {
            return [.paragraph([.wikiLink(target: target.linkTarget, label: nil, isEmbed: true)])]
        }
        // Else the database whose folder holds the rows the table links to.
        if let href = table.firstDescendant(where: { $0.hasClass("cell-title") })?
            .firstDescendant(where: { $0.tagName == "a" })?.attributes["href"]
        {
            let rowPath = resolvedComponents(percentDecoded(href))
            if rowPath.count >= 2, let folder = rowPath.dropLast().last {
                let databasePath = Array(rowPath.dropLast(2)) + [folder + ".html"]
                if let databaseIdentifier = resolver.pageIdentifier(atExportPath: databasePath),
                    let target = resolver.target(ofPage: databaseIdentifier), target.isBase
                {
                    return [.paragraph([.wikiLink(target: target.linkTarget, label: nil, isEmbed: true)])]
                }
            }
        }
        let name = holder?.firstDescendant(where: { $0.hasClass("collection-title") })?.textContent
            .trimmingSpacesAndLineBreaks() ?? ""
        note(.simplified, "the database \(name.isEmpty ? "without a title" : "“\(name)”") is not in the export, so its table was written as a Markdown table")
        var result: [MarkdownBlock] = []
        if !name.isEmpty { result.append(.paragraph([.strong([.text(name)])])) }
        let headerCells = table.descendants(where: { $0.tagName == "th" }).map { [MarkdownInline.text(textWithoutIcons($0).trimmingSpacesAndLineBreaks())] }
        let rows = table.descendants(where: { $0.tagName == "tr" && $0.parent?.tagName == "tbody" }).map { row in
            row.elementChildren.filter { $0.tagName == "td" }.map { cell in databaseCell(cell) }
        }
        result.append(.table(header: headerCells, rows: rows))
        return result
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
            return NotionDatabaseTable.Column(name: textWithoutIcons(cell).trimmingSpacesAndLineBreaks(),
                                              notionType: typeClass.map(NotionPropertyReader.notionType(ofIconClass:)),
                                              isTitle: typeClass == "typesTitle")
        }
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
        return NotionDatabaseTable(columns: tableColumns, rowPageIdentifiers: identifiers, rowTitles: titles)
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
                let color = node.classes.first(where: { $0.hasPrefix("highlight-") }).map { String($0.dropFirst("highlight-".count)) } ?? ""
                let children = inlines(of: node.children)
                if color == "default" || color == "gray" || color.isEmpty {
                    result.append(contentsOf: children)
                } else {
                    result.append(.highlight(children))
                }
            case "code":
                result.append(.code(node.textContent))
            case "a":
                result.append(contentsOf: link(node))
            case "time":
                result.append(.text(node.textContent.replacingEvery("@", with: "")))
            case "img":
                if node.hasClass("icon") { continue }
                if let source = node.attributes["src"] {
                    if let target = attachmentTarget(forHref: source) {
                        result.append(.wikiLink(target: target, label: nil, isEmbed: true))
                    } else if let name = missingPicture(source) {
                        result.append(.text(name))
                    } else {
                        result.append(.image(source: source, alternativeText: node.attributes["alt"] ?? ""))
                    }
                }
            case "span":
                if node.hasClass("notion-text-equation-token") {
                    result.append(.math(node.firstDescendant(where: { $0.tagName == "annotation" })?.textContent ?? ""))
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
        switch resolve(href: href) {
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
            return .external(href)
        }
        if lowered.hasPrefix("data:") {
            return .unresolved("an image held inside the page")
        }
        if lowered.hasPrefix("mailto:") || lowered.hasPrefix("tel:") || href.contains(text: "://") {
            return .external(href)
        }
        let withoutFragment = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = percentDecoded(String(withoutFragment[0]))
        let fragment = withoutFragment.count > 1 ? String(withoutFragment[1]) : nil
        let components = resolvedComponents(path)
        if let last = components.last, last.lowercased().hasSuffix(".html") {
            let name = NotionExportEntryName(last)
            if let identifier = name?.pageIdentifier ?? resolver.pageIdentifier(atExportPath: components),
                let target = resolver.target(ofPage: identifier) ?? resolver.pageIdentifier(atExportPath: components)
                    .flatMap({ resolver.target(ofPage: $0) })
            {
                let blockIdentifier = fragment.flatMap(NotionPageReader.hyphenatedIdentifier)
                return .page(target, heading: blockIdentifier.flatMap { heading(inPage: identifier, block: $0) })
            }
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

    /// An identifier written with or without hyphens, as Notion's API writes it: lowercase, hyphenated.
    static func hyphenatedIdentifier(_ text: String) -> String? {
        let digits = text.lowercased().filter { $0 != "-" }
        guard digits.count == 32, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return NotionExportEntryName("x \(digits)")?.pageIdentifier
    }

    // MARK: Properties

    private mutating func readProperty(_ row: HTMLNode) -> NotionPropertyReader.Property? {
        guard let name = row.elementChildren.first(where: { $0.tagName == "th" }).map({ textWithoutIcons($0) })?
            .trimmingSpacesAndLineBreaks(), !name.isEmpty,
            let cell = row.elementChildren.first(where: { $0.tagName == "td" })
        else { return nil }
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
        return property
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
