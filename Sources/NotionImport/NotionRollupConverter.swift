/**
 * File: NotionRollupConverter.swift
 * ---------------------------------
 * Layer: Notion
 * Description: A Notion rollup written as a Bases formula over the notes its relation links to, in the functions
 *              Obsidian 1.15 and Graphite both evaluate, or refused by its function's name when Bases has none.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import ImporterCore

/// Converts Notion's rollups.
///
/// A rollup reads a property of the pages its database's relation links to and works something out over them. In
/// the vault the relation is a list of links in each row's note, and the related pages are notes, so the rollup is a
/// formula of the base: the links turned into files, their property read, and the same calculation. Nothing is
/// stored in the notes, so it follows later edits as Notion's did.
enum NotionRollupConverter {
    /// What the rollup reads of each related note.
    enum Target: Equatable, Sendable {
        /// The related page's title: the note's name.
        case title
        /// A property of the related note, by the name the note gives it.
        case property(String)
    }

    /// The formula of a rollup over the relation property `relation` reading `target`, with Notion's `function`
    /// (`sum`, `percent_checked`…), or `nil` when Bases has no counterpart for the function.
    static func formula(relation: String, target: Target, function: String) -> String? {
        let notes = "list(note" + member(relation) + ").filter(value).map(value.asFile()).filter(value)"
        let values: String
        switch target {
        case .title: values = notes + ".map(value.name)"
        case .property(let name): values = notes + ".map(value.properties" + member(name) + ")"
        }
        let filled = values + ".filter(!value.isEmpty())"
        let checked = values + ".filter(value == true)"
        func percent(_ part: String) -> String {
            "if(" + notes + ".length == 0, 0, (" + part + ".length / " + notes + ".length * 100).round())"
        }
        switch function {
        case "show_original": return target == .title ? notes : values
        case "count", "count_all": return notes + ".length"
        case "count_values", "not_empty": return filled + ".length"
        case "empty": return "(" + notes + ".length - " + filled + ".length)"
        case "unique", "count_unique_values": return values + ".unique().length"
        case "show_unique": return values + ".unique()"
        case "percent_not_empty": return percent(filled)
        case "percent_empty": return "(100 - " + percent(filled) + ")"
        case "sum": return values + ".sum()"
        case "average": return values + ".mean()"
        case "median": return values + ".median()"
        case "min", "earliest_date": return values + ".min()"
        case "max", "latest_date": return values + ".max()"
        case "range": return "(" + values + ".max() - " + values + ".min())"
        case "checked": return checked + ".length"
        case "unchecked": return "(" + notes + ".length - " + checked + ".length)"
        case "percent_checked": return percent(checked)
        case "percent_unchecked": return "(100 - " + percent(checked) + ")"
        default: return nil
        }
    }

    /// `.name`, or `["name"]` with its quotes escaped when the name is not an identifier.
    static func member(_ name: String) -> String {
        if isIdentifier(name) { return "." + name }
        return "[\"" + name.replacingEvery("\\", with: "\\\\").replacingEvery("\"", with: "\\\"") + "\"]"
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || isASCIILetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
