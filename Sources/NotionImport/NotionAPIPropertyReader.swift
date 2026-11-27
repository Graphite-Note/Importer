/**
 * File: NotionAPIPropertyReader.swift
 * -----------------------------------
 * Layer: Notion
 * Description: A page's properties as Notion's API gives them, written as Obsidian properties of the same types as the
 *              HTML export's: text, numbers, check boxes, dates, lists, tags, and relations as links.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import ImporterCore

/// What a property's value links to, as the import placed it.
public protocol NotionAPIPropertyResolving: NotionAPILinkResolving {
    /// The title of a page the import does not hold, read from Notion, for a relation that leaves the import.
    func title(ofPage identifier: String) -> String?
}

/// Reads the properties of a page (a database row, or a page with properties).
public struct NotionAPIPropertyReader {
    /// A property read.
    public struct Property: Equatable, Sendable {
        public var name: String
        public var value: PropertyValue
        public var type: PropertyType
    }

    /// What was simplified, for the import report.
    public private(set) var findings: [NotionPageFinding] = []
    private let resolver: any NotionAPIPropertyResolving
    /// Properties the base computes instead (formulas Bases can express), left out of the notes.
    private let formulaNames: Set<String>

    public init(resolver: any NotionAPIPropertyResolving, formulaNames: Set<String> = []) {
        self.resolver = resolver
        self.formulaNames = formulaNames
    }

    private mutating func note(_ severity: ImportReport.Severity, _ message: String) {
        let finding = NotionPageFinding(severity: severity, message: message)
        if !findings.contains(finding) { findings.append(finding) }
    }

    /// The page's title, from its `title` property.
    public static func title(of properties: JSONValue) -> String {
        for member in properties.members where member.value["type"]?.string == "title" {
            let title = (member.value["title"]?.elements ?? []).compactMap { $0["plain_text"]?.string }.joined()
            return title
        }
        return ""
    }

    /// The properties of `properties` (a page's `properties` object), in Notion's order, the title left out (it names
    /// the note).
    public mutating func read(_ properties: JSONValue) -> [Property] {
        var result: [Property] = []
        for (name, value) in properties.members {
            guard let type = value["type"]?.string, type != "title", !formulaNames.contains(name) else { continue }
            if let property = read(name: name, type: type, value: value) { result.append(property) }
        }
        return result
    }

    /// The Obsidian type a Notion property type is written as.
    public static func propertyType(ofNotionType notionType: String, name: String) -> PropertyType {
        switch notionType {
        case "checkbox": return .checkbox
        case "number", "unique_id": return .number
        case "date", "created_time", "last_edited_time": return .date
        case "multi_select": return name.lowercased() == "tags" ? .tags : .multitext
        case "relation", "files", "people": return .multitext
        default: return .text
        }
    }

    private mutating func read(name: String, type: String, value: JSONValue) -> Property? {
        let content = value[type] ?? .null
        switch type {
        case "rich_text":
            let text = NotionAPIPropertyReader.plainText(content)
            return text.isEmpty ? nil : Property(name: name, value: .text(text), type: .text)
        case "number":
            guard let number = content.numberText else { return nil }
            return Property(name: name, value: .number(number), type: .number)
        case "checkbox":
            return Property(name: name, value: .checkbox(content.bool ?? false), type: .checkbox)
        case "select", "status":
            guard let option = content["name"]?.string else { return nil }
            return Property(name: name, value: .text(option), type: .text)
        case "multi_select":
            let options = content.elements.compactMap { $0["name"]?.string }
            guard !options.isEmpty else { return nil }
            if name.lowercased() == "tags" {
                // A tag cannot hold a space.
                return Property(name: "tags", value: .list(options.map { $0.replacingEvery(" ", with: "-") }), type: .tags)
            }
            return Property(name: name, value: .list(options), type: .multitext)
        case "date":
            return date(name: name, content)
        case "created_time", "last_edited_time":
            guard let text = content.string, let (date, hasTime) = NotionAPIPropertyReader.propertyDate(text) else { return nil }
            return Property(name: name, value: .date(date), type: hasTime ? .datetime : .date)
        case "people":
            let names = content.elements.compactMap { $0["name"]?.string }
            return names.isEmpty ? nil : Property(name: name, value: .list(names), type: .multitext)
        case "created_by", "last_edited_by":
            guard let person = content["name"]?.string else { return nil }
            return Property(name: name, value: .text(person), type: .text)
        case "files":
            let files = content.elements.compactMap { file -> String? in
                if let url = file["file"]?["url"]?.string { return resolver.attachmentTarget(forFile: url).map { "[[\($0)]]" } ?? file["name"]?.string }
                return file["external"]?["url"]?.string ?? file["name"]?.string
            }
            return files.isEmpty ? nil : Property(name: name, value: .list(files), type: .multitext)
        case "relation":
            let links = content.elements.compactMap { related -> String? in
                guard let identifier = related["id"]?.string else { return nil }
                if let target = resolver.target(ofPage: identifier) {
                    return "[[\(target)]]"
                }
                if let title = resolver.title(ofPage: identifier) {
                    note(.simplified, "a relation in “\(name)” to a page the import does not hold was kept as its title")
                    return title
                }
                note(.leftOut, "a relation in “\(name)” to a page not shared with the integration was left out")
                return nil
            }
            if value["has_more"]?.bool == true {
                note(.simplified, "the relation “\(name)” has more than the 25 pages Notion gives with a page: the others were left out")
            }
            return Property(name: name, value: .list(links), type: .multitext)
        case "url", "email", "phone_number":
            guard let text = content.string, !text.isEmpty else { return nil }
            return Property(name: name, value: .text(text), type: .text)
        case "unique_id":
            guard let number = content["number"]?.numberText else { return nil }
            if let prefix = content["prefix"]?.string, !prefix.isEmpty {
                return Property(name: name, value: .text(prefix + "-" + number), type: .text)
            }
            return Property(name: name, value: .number(number), type: .number)
        case "formula":
            return computed(name: name, content, kind: "formula")
        case "rollup":
            return computed(name: name, content, kind: "rollup")
        case "button", "verification":
            return nil
        default:
            note(.leftOut, "the property “\(name)” has a type the importer does not know (\(type)), so it was left out")
            return nil
        }
    }

    /// A formula's or a rollup's result, as its value when the import was made.
    private mutating func computed(name: String, _ content: JSONValue, kind: String) -> Property? {
        note(.simplified, "the \(kind) “\(name)” was written as its value when imported, which does not follow later changes")
        switch content["type"]?.string {
        case "string":
            guard let text = content["string"]?.string, !text.isEmpty else { return nil }
            return Property(name: name, value: .text(text), type: .text)
        case "number":
            guard let number = content["number"]?.numberText else { return nil }
            return Property(name: name, value: .number(number), type: .number)
        case "boolean":
            return Property(name: name, value: .checkbox(content["boolean"]?.bool ?? false), type: .checkbox)
        case "date":
            return date(name: name, content["date"] ?? .null)
        case "array":
            let values = (content["array"]?.elements ?? []).compactMap { element -> String? in
                guard let type = element["type"]?.string else { return nil }
                return read(name: name, type: type, value: element).flatMap { property in
                    switch property.value {
                    case .text(let text), .number(let text), .date(let text): return text
                    case .checkbox(let checked): return checked ? "true" : "false"
                    case .list(let items): return items.joined(separator: ", ")
                    }
                }
            }
            return values.isEmpty ? nil : Property(name: name, value: .list(values), type: .multitext)
        default:
            return nil
        }
    }

    private mutating func date(name: String, _ content: JSONValue) -> Property? {
        guard let start = content["start"]?.string, let (startDate, startHasTime) = NotionAPIPropertyReader.propertyDate(start) else { return nil }
        if let end = content["end"]?.string, let (endDate, endHasTime) = NotionAPIPropertyReader.propertyDate(end) {
            note(.simplified, "a range of dates in the property “\(name)” was kept as text, which Obsidian's properties cannot type")
            return Property(name: name, value: .text(startDate + " → " + endDate), type: startHasTime || endHasTime ? .datetime : .date)
        }
        return Property(name: name, value: .date(startDate), type: startHasTime ? .datetime : .date)
    }

    /// An ISO date of Notion's (`2024-06-01`, `2024-06-01T10:00:00.000+02:00`) as a property writes it: the date, and
    /// the time of day as written, to the minute, in the time zone it was written in.
    static func propertyDate(_ text: String) -> (String, Bool)? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 10 else { return nil }
        let date = String(String.UnicodeScalarView(scalars[0..<10]))
        let isDigit: (Unicode.Scalar) -> Bool = { ("0"..."9").contains($0) }
        guard scalars[4] == "-", scalars[7] == "-", [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ isDigit(scalars[$0]) }) else { return nil }
        guard scalars.count >= 16, scalars[10] == "T" else { return (date, false) }
        let time = String(String.UnicodeScalarView(scalars[11..<16]))
        return (date + "T" + time, true)
    }

    static func plainText(_ richText: JSONValue) -> String {
        richText.elements.compactMap { $0["plain_text"]?.string }.joined()
    }
}
