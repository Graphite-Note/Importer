/**
 * File: NotionAPIPageReader.swift
 * -------------------------------
 * Layer: Notion
 * Description: A page's blocks as Notion's API gives them, turned into the same Markdown model as the HTML export's
 *              pages: rich text with its marks and mentions, lists, to-dos, toggles, callouts, code, math, tables,
 *              files, synced blocks, columns and AI meeting notes.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 28/11/2026
 */

import ImporterCore

/// A block as `GET /v1/blocks/{id}/children` gives it, with its own children read the same way. A meeting notes block
/// (`transcription`, `meeting_notes`) has its summary, notes and transcript read from the blocks it names, as sections.
public struct NotionAPIBlock: Sendable {
    public var json: JSONValue
    public var children: [NotionAPIBlock]
    /// A meeting notes block's sections, in order: their titles and blocks.
    public var sections: [(title: String, blocks: [NotionAPIBlock])]

    public init(json: JSONValue, children: [NotionAPIBlock] = [], sections: [(title: String, blocks: [NotionAPIBlock])] = []) {
        self.json = json
        self.children = children
        self.sections = sections
    }

    public var type: String { json["type"]?.string ?? "" }
    public var identifier: String { json["id"]?.string ?? "" }
    public var hasChildren: Bool { json["has_children"]?.bool == true }
    /// The object named by the block's type (`json["paragraph"]` for a paragraph).
    public var content: JSONValue { json[type] ?? .null }
}

/// What a page's blocks link to, as the import has placed it.
public protocol NotionAPILinkResolving {
    /// The wiki link target of a page of the import (its note), `nil` for a page the import does not hold.
    func target(ofPage identifier: String) -> String?
    /// The wiki link target of a database of the import (its base).
    func target(ofDatabase identifier: String) -> String?
    /// The wiki link target of a file the import downloaded from `url`, `nil` when it was not downloaded.
    func attachmentTarget(forFile url: String) -> String?
}

/// Reads a page's blocks into Markdown, with what had to be simplified or left out.
public struct NotionAPIPageReader {
    private let resolver: any NotionAPILinkResolving
    private(set) var findings: [NotionPageFinding] = []
    /// The page's headings, for its table of contents: level and text.
    private var headings: [(level: Int, text: String)] = []

    init(resolver: any NotionAPILinkResolving) {
        self.resolver = resolver
    }

    /// The Markdown of `blocks` and the findings of their reading.
    public static func read(_ blocks: [NotionAPIBlock], resolver: any NotionAPILinkResolving) -> (blocks: [MarkdownBlock], findings: [NotionPageFinding]) {
        var reader = NotionAPIPageReader(resolver: resolver)
        reader.headings = NotionAPIPageReader.headings(in: blocks)
        let markdown = reader.convert(blocks)
        return (markdown, reader.findings)
    }

    /// The identifier without its hyphens, as the import keys pages and databases.
    public static func plainIdentifier(_ identifier: String) -> String {
        identifier.lowercased().unicodeScalars.filter { $0 != "-" }.map(String.init).joined()
    }

    private mutating func note(_ severity: ImportReport.Severity, _ message: String) {
        let finding = NotionPageFinding(severity: severity, message: message)
        if !findings.contains(finding) { findings.append(finding) }
    }

    // MARK: Blocks

    mutating func convert(_ blocks: [NotionAPIBlock]) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            switch block.type {
            case "bulleted_list_item", "to_do":
                var items: [MarkdownListItem] = []
                while index < blocks.count, blocks[index].type == "bulleted_list_item" || blocks[index].type == "to_do" {
                    items.append(listItem(blocks[index]))
                    index += 1
                }
                result.append(.bulletList(items))
                continue
            case "numbered_list_item":
                var items: [MarkdownListItem] = []
                while index < blocks.count, blocks[index].type == "numbered_list_item" {
                    items.append(listItem(blocks[index]))
                    index += 1
                }
                result.append(.numberedList(start: 1, items))
                continue
            default:
                result += convert(block)
            }
            index += 1
        }
        return result
    }

    private mutating func listItem(_ block: NotionAPIBlock) -> MarkdownListItem {
        let checkbox: Bool? = block.type == "to_do" ? (block.content["checked"]?.bool ?? false) : nil
        return MarkdownListItem(checkbox: checkbox, blocks: [.paragraph(inlines(block.content["rich_text"]))] + convert(block.children))
    }

    private mutating func convert(_ block: NotionAPIBlock) -> [MarkdownBlock] {
        let content = block.content
        switch block.type {
        case "paragraph":
            let text = inlines(content["rich_text"])
            var result: [MarkdownBlock] = MarkdownInlineNormalizer.isBlank(text) ? [] : [.paragraph(text)]
            if !block.children.isEmpty {
                note(.simplified, "blocks indented under a paragraph were written after it, without the indent")
                result += convert(block.children)
            }
            return result
        case "heading_1", "heading_2", "heading_3", "heading_4":
            let level = Int(String(block.type.last ?? "1")) ?? 1
            // A toggle heading stays a heading, its content after it, so links to it and the outline keep it.
            return [.heading(level: level, inlines(content["rich_text"]))] + convert(block.children)
        case "quote":
            return [.quote([.paragraph(inlines(content["rich_text"]))] + convert(block.children))]
        case "callout":
            let emoji = content["icon"]?["emoji"]?.string
            let iconAddress = content["icon"]?["external"]?["url"]?.string ?? content["icon"]?["file"]?["url"]?.string
            let type = NotionCallouts.calloutType(emoji: emoji, iconName: iconAddress.flatMap(NotionCallouts.iconName(fromSource:)))
            var title: [MarkdownInline] = emoji.map { [.text($0 + " ")] } ?? []
            title += inlines(content["rich_text"])
            return [.callout(type: type, title: MarkdownInlineNormalizer.normalize(title), folding: .notFoldable, body: convert(block.children))]
        case "toggle":
            return [.callout(type: "note", title: inlines(content["rich_text"]), folding: .folded, body: convert(block.children))]
        case "code":
            return [.codeBlock(language: NotionCallouts.codeLanguage(content["language"]?.string ?? ""), code: plainText(content["rich_text"]))]
        case "equation":
            return [.mathBlock(content["expression"]?.string ?? "")]
        case "divider":
            return [.thematicBreak]
        case "table":
            return table(block)
        case "bookmark", "embed", "link_preview":
            guard let url = content["url"]?.string, !url.isEmpty else { return [] }
            let caption = inlines(content["caption"])
            return [.paragraph([.link(destination: url, label: MarkdownInlineNormalizer.isBlank(caption) ? [.text(url)] : caption)])]
        case "image", "file", "pdf", "video", "audio":
            return file(block)
        case "child_page":
            let title = content["title"]?.string ?? "Untitled"
            if let target = resolver.target(ofPage: block.identifier) { return [.paragraph([.wikiLink(target: target, label: nil, isEmbed: false)])] }
            note(.leftOut, "the subpage “\(title)” is not part of the import, so its link was kept as text")
            return [.paragraph([.text(title)])]
        case "child_database":
            let title = content["title"]?.string ?? "Untitled"
            if let target = resolver.target(ofDatabase: block.identifier) { return [.paragraph([.wikiLink(target: target, label: nil, isEmbed: true)])] }
            note(.leftOut, "the database “\(title)” is not part of the import, so it was kept as its title")
            return [.paragraph([.text(title)])]
        case "link_to_page":
            if let page = content["page_id"]?.string {
                if let target = resolver.target(ofPage: page) { return [.paragraph([.wikiLink(target: target, label: nil, isEmbed: false)])] }
            } else if let database = content["database_id"]?.string ?? content["data_source_id"]?.string {
                if let target = resolver.target(ofDatabase: database) { return [.paragraph([.wikiLink(target: target, label: nil, isEmbed: true)])] }
            }
            note(.leftOut, "a link to a page the import does not hold was left out")
            return []
        case "synced_block":
            note(.simplified, "a synced block was copied into the note: later edits in Notion reach each copy only with a new import")
            return convert(block.children)
        case "column_list":
            note(.simplified, "a layout in columns was flattened into one column, the columns one after the other")
            return convert(block.children.flatMap { column in column.children })
        case "column":
            return convert(block.children)
        case "table_of_contents":
            return tableOfContents()
        case "transcription", "meeting_notes":
            return meetingNotes(block)
        case "breadcrumb":
            note(.leftOut, "a breadcrumb was left out: a note's place shows in the file list")
            return []
        case "template":
            note(.leftOut, "a template button was left out")
            return []
        case "unsupported":
            note(.leftOut, "a block Notion's API does not give was left out")
            return []
        default:
            note(.leftOut, "a block of the type “\(block.type)” was left out")
            return []
        }
    }

    private mutating func table(_ block: NotionAPIBlock) -> [MarkdownBlock] {
        let rows = block.children.filter { $0.type == "table_row" }.map { row in row.content["cells"]?.elements.map { cell in inlines(cell) } ?? [] }
        guard let first = rows.first else { return [] }
        if block.content["has_column_header"]?.bool != true {
            note(.simplified, "a table without a header row was given its first row as header, as Markdown tables need one")
        }
        if block.content["has_row_header"]?.bool == true {
            note(.simplified, "a table's row header was written as an ordinary first column")
        }
        return [.table(header: first, rows: Array(rows.dropFirst()))]
    }

    private mutating func file(_ block: NotionAPIBlock) -> [MarkdownBlock] {
        let content = block.content
        let caption = inlines(content["caption"])
        var result: [MarkdownBlock] = []
        if let url = content["file"]?["url"]?.string {
            if let target = resolver.attachmentTarget(forFile: url) {
                result.append(.paragraph([.wikiLink(target: target, label: nil, isEmbed: true)]))
            } else {
                let name = content["name"]?.string ?? "a file"
                note(.failed, "the file \(name) could not be downloaded, so it is missing")
                result.append(.paragraph([.text(name)]))
            }
        } else if let url = content["external"]?["url"]?.string {
            if block.type == "image" {
                result.append(.paragraph([.image(source: url, alternativeText: plainText(content["caption"]))]))
            } else {
                result.append(.paragraph([.link(destination: url, label: [.text(content["name"]?.string ?? url)])]))
            }
        }
        if !MarkdownInlineNormalizer.isBlank(caption) { result.append(.paragraph(caption)) }
        return result
    }

    private static func headings(in blocks: [NotionAPIBlock]) -> [(level: Int, text: String)] {
        var result: [(level: Int, text: String)] = []
        for block in blocks {
            if block.type.hasPrefix("heading_"), let level = Int(String(block.type.last ?? "1")) {
                let text = (block.content["rich_text"]?.elements ?? []).compactMap { $0["plain_text"]?.string }.joined()
                result.append((level, text))
            }
            if block.type != "child_page" { result += headings(in: block.children) }
        }
        return result
    }

    private func tableOfContents() -> [MarkdownBlock] {
        guard let topLevel = headings.map({ heading in heading.level }).min() else { return [] }
        let (list, _) = NotionAPIPageReader.nestedItems(headings, from: 0, level: topLevel)
        return list.isEmpty ? [] : [.bulletList(list)]
    }

    private static func nestedItems(_ headings: [(level: Int, text: String)], from start: Int, level: Int) -> ([MarkdownListItem], Int) {
        var items: [MarkdownListItem] = []
        var index = start
        while index < headings.count, headings[index].level >= level {
            if headings[index].level > level, !items.isEmpty {
                let (nested, next) = nestedItems(headings, from: index, level: headings[index].level)
                items[items.count - 1].blocks.append(.bulletList(nested))
                index = next
                continue
            }
            let text = NotionPageReader.headingLinkText(headings[index].text)
            items.append(MarkdownListItem(blocks: [.paragraph([.wikiLink(target: "#" + text, label: headings[index].text, isEmbed: false)])]))
            index += 1
        }
        return (items, index)
    }

    /// AI meeting notes: the meeting's title as a heading, then its summary, notes and transcript as sections under it.
    private mutating func meetingNotes(_ block: NotionAPIBlock) -> [MarkdownBlock] {
        let title = inlines(block.content["title"])
        // Without a title, the sections stand at the title's level.
        let hasTitle = !MarkdownInlineNormalizer.isBlank(title)
        var result: [MarkdownBlock] = hasTitle ? [.heading(level: 2, title)] : []
        for section in block.sections where !section.blocks.isEmpty {
            result.append(.heading(level: hasTitle ? 3 : 2, [.text(section.title)]))
            result += convert(section.blocks)
        }
        return result
    }

    // MARK: Rich text

    func plainText(_ richText: JSONValue?) -> String {
        (richText?.elements ?? []).compactMap { $0["plain_text"]?.string }.joined()
    }

    /// The inline Markdown of a rich text array: each run with its marks, links and mentions.
    mutating func inlines(_ richText: JSONValue?) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for run in richText?.elements ?? [] {
            result += inline(run)
        }
        return MarkdownInlineNormalizer.normalize(result)
    }

    private mutating func inline(_ run: JSONValue) -> [MarkdownInline] {
        let text = run["plain_text"]?.string ?? ""
        var content: [MarkdownInline]
        switch run["type"]?.string {
        case "equation":
            return [.math(run["equation"]?["expression"]?.string ?? text)]
        case "mention":
            content = mention(run["mention"] ?? .null, text: text)
        default:
            if let url = run["text"]?["link"]?["url"]?.string ?? run["href"]?.string {
                content = [link(to: url, label: [.text(text)])]
            } else {
                content = [.text(text)]
            }
        }
        let annotations = run["annotations"] ?? .null
        if annotations["code"]?.bool == true, case .text(let plain)? = content.first, content.count == 1 { content = [.code(plain)] }
        if annotations["bold"]?.bool == true { content = [.strong(content)] }
        if annotations["italic"]?.bool == true { content = [.emphasis(content)] }
        if annotations["strikethrough"]?.bool == true { content = [.strikethrough(content)] }
        if annotations["underline"]?.bool == true { content = [.underline(content)] }
        if let color = annotations["color"]?.string {
            if color.hasSuffix("_background") {
                content = [.highlight(content)]
            } else if let hex = NotionColors.textColor(named: color) {
                content = [.textColor(hex, content)]
            }
        }
        return content
    }

    /// A link: a wiki link when it points at a page of the import (Notion writes those as its own addresses).
    private mutating func link(to url: String, label: [MarkdownInline]) -> MarkdownInline {
        if let identifier = NotionAPIPageReader.pageIdentifier(inAddress: url), let target = resolver.target(ofPage: identifier) {
            return .wikiLink(target: target, label: MarkdownInlineNormalizer.plainText(of: label), isEmbed: false)
        }
        return .link(destination: url, label: label)
    }

    private mutating func mention(_ mention: JSONValue, text: String) -> [MarkdownInline] {
        switch mention["type"]?.string {
        case "page":
            let identifier = mention["page"]?["id"]?.string ?? ""
            if let target = resolver.target(ofPage: identifier) { return [.wikiLink(target: target, label: nil, isEmbed: false)] }
            note(.leftOut, "a mention of a page the import does not hold was kept as its title")
            return [.text(text)]
        case "database":
            let identifier = mention["database"]?["id"]?.string ?? ""
            if let target = resolver.target(ofDatabase: identifier) { return [.wikiLink(target: target, label: nil, isEmbed: false)] }
            note(.leftOut, "a mention of a database the import does not hold was kept as its title")
            return [.text(text)]
        case "date":
            let date = mention["date"] ?? .null
            let start = date["start"]?.string ?? text
            if let end = date["end"]?.string { return [.text(start + " → " + end)] }
            return [.text(start)]
        case "link_preview", "link_mention":
            let url = mention["link_preview"]?["url"]?.string ?? mention["link_mention"]?["href"]?.string ?? text
            return [.link(destination: url, label: [.text(text.isEmpty ? url : text)])]
        default:
            // A user, a template's date or another mention: its words.
            return [.text(text)]
        }
    }

    /// The page identifier of a Notion address (`https://www.notion.so/Title-1a2b…`, with or without a block's `#…`).
    static func pageIdentifier(inAddress url: String) -> String? {
        let lowered = url.lowercased()
        guard lowered.contains(text: "notion.so/") || lowered.contains(text: "notion.site/") || lowered.hasPrefix("/") else { return nil }
        let path = lowered.pieces(separatedBy: "#")[0].pieces(separatedBy: "?")[0]
        let last = path.pieces(separatedBy: "/").last ?? ""
        let hexadecimal = last.unicodeScalars.filter { $0 != "-" }.map(String.init).joined()
        guard hexadecimal.count >= 32 else { return nil }
        let identifier = String(hexadecimal.suffix(32))
        guard identifier.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return identifier
    }
}
