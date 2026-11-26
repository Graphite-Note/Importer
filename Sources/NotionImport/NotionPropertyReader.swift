/**
 * File: NotionPropertyReader.swift
 * --------------------------------
 * Layer: Notion
 * Description: Reads one property of a Notion page (a row of its `properties` table, typed by its `property-row-*`
 *              class) into a typed Obsidian property: text, number, check box, date, list, links to pages and files.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation
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
        let text = cell.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        switch notionType {
        case "checkbox":
            return Property(name: name, value: .checkbox(cell.firstDescendant(where: { $0.hasClass("checkbox-on") }) != nil),
                            type: .checkbox)
        case "number", "auto_increment_id":
            guard !text.isEmpty else { return nil }
            if let number = NotionPropertyReader.number(text) {
                return Property(name: name, value: .number(number), type: .number)
            }
            return Property(name: name, value: .text(text), type: .number)
        case "date", "created_time", "last_edited_time":
            return date(name: name, cell: cell, text: text)
        case "multi_select":
            let values = selectedValues(in: cell)
            guard !values.isEmpty else { return nil }
            if name.lowercased() == "tags" {
                // A tag cannot hold a space.
                return Property(name: "tags", value: .list(values.map { $0.replacingOccurrences(of: " ", with: "-") }), type: .tags)
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
                $0.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
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
            $0.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private mutating func date(name: String, cell: HTMLNode, text: String) -> Property? {
        let times = cell.descendants(where: { $0.tagName == "time" })
        let written = (times.isEmpty ? text : times.map(\.textContent).joined(separator: " → "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return nil }
        guard let dates = dateParser.parseRange(written) else {
            warning = "the date “\(written)” of the property “\(name)” could not be read, so it was kept as text"
            return Property(name: name, value: .text(written), type: .date)
        }
        let type: PropertyType = dates.contains(where: { $0.time != nil }) ? .datetime : .date
        if dates.count == 2 {
            warning = "a range of dates in the property “\(name)” was kept as text, which Obsidian's properties cannot type"
            return Property(name: name, value: .text(dates.map(\.propertyText).joined(separator: " → ")), type: type)
        }
        return Property(name: name, value: .date(dates[0].propertyText), type: type)
    }

    /// A number as a property writes it, `nil` when `text` is no plain number (`$1,234.56` and `15%` stay text).
    static func number(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite,
            cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "e" || $0 == "E" || $0 == "+" })
        else { return nil }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}
