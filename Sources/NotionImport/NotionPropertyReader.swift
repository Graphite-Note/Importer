/**
 * File: NotionPropertyReader.swift
 * --------------------------------
 * Layer: Notion
 * Description: Reads one property of a Notion page (a row of its `properties` table, typed by its `property-row-*`
 *              class) into a typed Obsidian property: text, number, check box, date, list, links to pages and files.
 *
 * Authors: Bahey Shalash
 * Version: 0.4
 * Date: 28/11/2026
 */

import ImporterCore

/// Reads a property's value from its table cell.
public struct NotionPropertyReader {
    /// A property read.
    public struct Property: Equatable, Sendable {
        public var name: String
        public var value: PropertyValue
        public var type: PropertyType
    }

    private let dateParser: NotionDateParser
    /// What was simplified in the last property read, for the import report.
    public private(set) var warning: String?
    /// The end of the range of dates the last property read holds, as the property `<name> end`.
    public private(set) var rangeEnd: Property?

    /// The report's line for a number property Notion shows formatted, the same for every note, so that it is said once.
    public static func formatMessage(property name: String, format: String) -> String {
        "numbers of the property “\(name)” are written as numbers, without Notion's \(format) format"
    }

    /// The report's line for a property holding ranges of dates, the same for every note, so that it is said once.
    public static func rangeMessage(property name: String) -> String {
        "ranges of dates in the property “\(name)” were written as “\(name)”, their start, and “\(name) end”: a property holds one date"
    }

    public init(dateParser: NotionDateParser) {
        self.dateParser = dateParser
    }

    /// The Notion type a database column's icon names: `typesMultipleSelect` gives `multi_select`.
    public static func notionType(ofIconClass iconClass: String) -> String {
        let names: [String: String] = [
            "typesTitle": "title", "typesText": "text", "typesNumber": "number", "typesSelect": "select",
            "typesMultipleSelect": "multi_select", "typesStatus": "status", "typesDate": "date", "typesPerson": "person",
            "typesFile": "file", "typesCheckbox": "checkbox", "typesUrl": "url", "typesEmail": "email",
            "typesPhoneNumber": "phone_number", "typesFormula": "formula", "typesRelation": "relation",
            "typesRollup": "rollup", "typesCreatedAt": "created_time", "typesCreatedBy": "created_by",
            "typesLastEditedAt": "last_edited_time", "typesLastEditedTime": "last_edited_time",
            "typesLastEditedBy": "last_edited_by", "typesAutoIncrementId": "auto_increment_id", "typesPlace": "place",
            "typesButton": "button", "typesVerification": "verification",
        ]
        if let name = names[iconClass] { return name }
        return String(iconClass.dropFirst("types".count)).lowercased()
    }

    /// The Obsidian type a Notion type is written as, before its values are seen (a date column may hold times).
    public static func propertyType(ofNotionType notionType: String, name: String) -> PropertyType {
        switch notionType {
        case "checkbox": return .checkbox
        case "number", "auto_increment_id": return .number
        case "date", "created_time", "last_edited_time": return .date
        case "multi_select": return name.lowercased() == "tags" ? .tags : .multitext
        case "relation", "file": return .multitext
        default: return .text
        }
    }

    /// The property `name` of Notion type `notionType`, from its `cell`, `nil` when it holds nothing. `links` are the
    /// cell's links already resolved: wiki links to pages and attachments, addresses for the rest.
    public mutating func read(name: String, notionType: String, cell: HTMLNode, links: [String]) -> Property? {
        warning = nil
        rangeEnd = nil
        let text = cell.textContent.trimmingSpacesAndLineBreaks()
        switch notionType {
        case "checkbox":
            return Property(name: name, value: .checkbox(cell.firstDescendant(where: { $0.hasClass("checkbox-on") }) != nil),
                            type: .checkbox)
        case "number", "auto_increment_id":
            guard !text.isEmpty else { return nil }
            if let number = NotionPropertyReader.number(text) {
                return Property(name: name, value: .number(number), type: .number)
            }
            if let (number, format) = NotionPropertyReader.formattedNumber(text) {
                warning = NotionPropertyReader.formatMessage(property: name, format: format)
                return Property(name: name, value: .number(number), type: .number)
            }
            warning = "the number “\(text)” of the property “\(name)” could not be read, so it was kept as text"
            return Property(name: name, value: .text(text), type: .text)
        case "date", "created_time", "last_edited_time":
            return date(name: name, cell: cell, text: text)
        case "multi_select":
            let values = selectedValues(in: cell)
            guard !values.isEmpty else { return nil }
            if name.lowercased() == "tags" {
                // A tag cannot hold a space.
                return Property(name: "tags", value: .list(values.map { $0.replacingEvery(" ", with: "-") }), type: .tags)
            }
            return Property(name: name, value: .list(values), type: .multitext)
        case "select", "status":
            let values = selectedValues(in: cell)
            let value = values.isEmpty ? text : values.joined(separator: ", ")
            return value.isEmpty ? nil : Property(name: name, value: .text(value), type: .text)
        case "relation", "file":
            let values = links.filter { !$0.isEmpty }
            if values.isEmpty {
                return text.isEmpty ? nil : Property(name: name, value: .list([text]), type: .multitext)
            }
            return Property(name: name, value: .list(values), type: .multitext)
        case "url":
            let value = links.first ?? text
            return value.isEmpty ? nil : Property(name: name, value: .text(value), type: .text)
        case "person", "created_by", "last_edited_by":
            let users = cell.descendants(where: { $0.hasClass("user") }).map {
                $0.textContent.trimmingSpacesAndLineBreaks()
            }.filter { !$0.isEmpty }
            let value = users.isEmpty ? text : users.joined(separator: ", ")
            return value.isEmpty ? nil : Property(name: name, value: .text(value), type: .text)
        case "formula", "rollup":
            if cell.firstDescendant(where: { $0.hasClass("checkbox") }) != nil {
                return Property(name: name, value: .checkbox(cell.firstDescendant(where: { $0.hasClass("checkbox-on") }) != nil),
                                type: .text)
            }
            return text.isEmpty ? nil : Property(name: name, value: .text(text), type: .text)
        case "button":
            return nil
        default:
            if !["text", "title", "email", "phone_number", "place", "verification"].contains(notionType) {
                warning = "the property “\(name)” has a type the importer does not know (\(notionType)), so it was kept as text"
            }
            return text.isEmpty ? nil : Property(name: name, value: .text(text), type: .text)
        }
    }

    private func selectedValues(in cell: HTMLNode) -> [String] {
        cell.descendants(where: { $0.hasClass("selected-value") }).map {
            $0.textContent.trimmingSpacesAndLineBreaks()
        }.filter { !$0.isEmpty }
    }

    private mutating func date(name: String, cell: HTMLNode, text: String) -> Property? {
        let times = cell.descendants(where: { $0.tagName == "time" })
        let written = (times.isEmpty ? text : times.map({ $0.textContent }).joined(separator: " → ")).trimmingSpacesAndLineBreaks()
        guard !written.isEmpty else { return nil }
        var dates = dateParser.parseRange(written)
        // Since 2025 a date also gives its exact start (`datetime="2026-05-03T14:00"`), which a numeric date such as
        // 03/05/2026 cannot. A range's end is only in its text, after the arrow.
        let exact = times.compactMap { $0.attributes["datetime"] }.compactMap { dateParser.parse($0) }
        if let start = exact.first {
            if !written.contains(text: "→") {
                dates = [start]
            } else if let range = dates, range.count == 2 {
                dates = [start, range[1]]
            } else if let end = written.pieces(separatedBy: "→").last.flatMap({ dateParser.parse($0.trimmingSpaces()) }) {
                dates = [start, end]
            }
        }
        guard let dates else {
            warning = "the date “\(written)” of the property “\(name)” could not be read, so it was kept as text"
            return Property(name: name, value: .text(written), type: .text)
        }
        let type: PropertyType = dates.contains(where: { $0.time != nil }) ? .datetime : .date
        if dates.count == 2 {
            rangeEnd = Property(name: name + " end", value: .date(dates[1].propertyText), type: type)
        }
        return Property(name: name, value: .date(dates[0].propertyText), type: type)
    }

    /// The number a formatted number of Notion's stands for, and the format: `15%` is 0.15 (Notion keeps a percent as its
    /// fraction), `£42,000.00` is 42000, `1,234` is 1234. `nil` for text that is no number so written.
    static func formattedNumber(_ text: String) -> (number: String, format: String)? {
        // Notion writes a no-break space between a currency's code and its amount (`CHF 9.90`).
        var body = text.map { $0.isWhitespace ? " " : String($0) }.joined().trimmingSpaces()
        var isPercent = false
        if body.hasSuffix("%") {
            isPercent = true
            body = String(body.dropLast()).trimmingSpaces()
        }
        var currency = ""
        // A currency's code before or after the amount (`CHF 9.90`, `12 EUR`).
        let words = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if words.count == 2, let code = words.first(where: NotionPropertyReader.isCurrencyCode) {
            currency = code
            body = words.first(where: { $0 != code }) ?? ""
        }
        while let first = body.first, currencySymbols.contains(first) {
            currency.append(first)
            body = String(body.dropFirst()).trimmingSpaces()
        }
        while let last = body.last, currencySymbols.contains(last) {
            currency = String(last) + currency
            body = String(body.dropLast()).trimmingSpaces()
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !body.isEmpty, parts.count <= 2 else { return nil }
        let groups = parts[0].split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 1 {
            let first = groups[0].hasPrefix("-") ? groups[0].dropFirst() : groups[0]
            guard (1...3).contains(first.count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let plain = groups.joined() + (parts.count == 2 ? "." + parts[1] : "")
        guard isPercent || !currency.isEmpty || groups.count > 1, let number = number(plain), let value = Double(number) else {
            return nil
        }
        if isPercent {
            let fraction = value / 100
            let written = fraction == fraction.rounded() && abs(fraction) < 1e15 ? String(Int64(fraction)) : String(fraction)
            return (written, "percent")
        }
        return (number, currency.isEmpty ? "thousands separator" : "currency (\(currency))")
    }

    /// Whether `word` is a currency's code as ISO 4217 writes them: three capital letters.
    static func isCurrencyCode(_ word: String) -> Bool {
        word.count == 3 && word.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    private static let currencySymbols: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "₺", "₪", "₫", "฿", "₴", "₦", "₱", "¢", "₣", "₡"]

    /// The Notion type a column's icon names since 2025, from its picture's address
    /// (`https://app.notion.com/icons/calendar_gray.svg` gives `date`), `nil` for an icon the person chose.
    public static func notionType(ofIconAddress address: String) -> String? {
        guard let file = address.split(separator: "/").last else { return nil }
        let name = String(file.split(separator: "_").first ?? file).split(separator: ".").first.map(String.init) ?? ""
        let types: [String: String] = [
            "font": "title", "description": "text", "hashtag": "number", "arrow-circle-down": "select", "list": "multi_select",
            "burst": "status", "calendar": "date", "friends": "person", "attachment": "file", "checkmark-square": "checkbox",
            "link": "url", "at": "email", "phone-call": "phone_number", "formula": "formula", "arrow-northeast": "relation",
            "search": "rollup", "clock": "created_time", "user-circle": "created_by", "key": "auto_increment_id",
            "location": "place", "cursor-button": "button",
        ]
        return types[name]
    }

    /// A number as a property writes it, `nil` when `text` is no plain number (`$1,234.56` and `15%` stay text).
    static func number(_ text: String) -> String? {
        let cleaned = text.trimmingSpaces()
        guard let value = Double(cleaned), value.isFinite,
            cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "e" || $0 == "E" || $0 == "+" })
        else { return nil }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}
