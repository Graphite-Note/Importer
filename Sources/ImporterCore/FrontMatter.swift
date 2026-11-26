/**
 * File: FrontMatter.swift
 * -----------------------
 * Layer: Core
 * Description: A note's properties (front matter) and their types, written as YAML in the form Obsidian writes it:
 *              plain scalars where YAML reads them back as the same text, quoted otherwise, lists one item a line.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

/// The type of a property, as Obsidian names it in `.obsidian/types.json`.
public enum PropertyType: String, Equatable, Sendable, CaseIterable {
    case text
    case number
    case checkbox
    case date
    case datetime
    case multitext
    case tags
}

/// The value of a property.
public enum PropertyValue: Equatable, Sendable {
    /// Text, quoted when YAML would read it as something else.
    case text(String)
    /// A number, as written (`12`, `67.3`).
    case number(String)
    /// A check box.
    case checkbox(Bool)
    /// A date (`2024-03-01`) or a date and time (`2024-03-01T14:30`).
    case date(String)
    /// A list of texts.
    case list([String])
}

/// A note's properties, in order.
public struct FrontMatter: Equatable, Sendable {
    /// The properties, by name, in the order they are written.
    public var properties: [(name: String, value: PropertyValue)]

    public init(properties: [(name: String, value: PropertyValue)] = []) {
        self.properties = properties
    }

    public static func == (left: FrontMatter, right: FrontMatter) -> Bool {
        left.properties.count == right.properties.count
            && zip(left.properties, right.properties).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    /// Whether there is no property.
    public var isEmpty: Bool {
        properties.isEmpty
    }

    /// The value of the property `name`.
    public subscript(name: String) -> PropertyValue? {
        properties.first(where: { $0.name == name })?.value
    }

    /// Sets the property `name`, in its place when it is there already, else at the end.
    public mutating func set(_ name: String, to value: PropertyValue) {
        if let index = properties.firstIndex(where: { $0.name == name }) {
            properties[index].value = value
        } else {
            properties.append((name, value))
        }
    }

    /// The YAML block between `---` lines, followed by a line end, or empty when there is no property.
    public var yaml: String {
        guard !properties.isEmpty else { return "" }
        var lines = ["---"]
        for (name, value) in properties {
            let key = YAMLScalar.quotedIfNeeded(name)
            switch value {
            case .text(let text):
                lines.append("\(key): \(YAMLScalar.quotedIfNeeded(text))")
            case .number(let number):
                lines.append("\(key): \(number)")
            case .checkbox(let isChecked):
                lines.append("\(key): \(isChecked ? "true" : "false")")
            case .date(let date):
                lines.append("\(key): \(date)")
            case .list(let items):
                if items.isEmpty {
                    lines.append("\(key): []")
                } else {
                    lines.append("\(key):")
                    lines.append(contentsOf: items.map { "  - \(YAMLScalar.quotedIfNeeded($0))" })
                }
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// YAML scalars written plain when YAML 1.2 reads them back as the same text, double-quoted otherwise.
public enum YAMLScalar {
    /// `text` as a YAML scalar that reads back as `text`.
    public static func quotedIfNeeded(_ text: String) -> String {
        needsQuotes(text) ? doubleQuoted(text) : text
    }

    /// `text` in double quotes, with `\`, `"` and control characters escaped.
    public static func doubleQuoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\u{2028}" || scalar == "\u{2029}" {
                    let digits = String(scalar.value, radix: 16, uppercase: true)
                    result += "\\u" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private static let indicatorCharacters: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!",
                                                              "|", ">", "'", "\"", "%", "@", "`"]
    private static let reservedWords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"]

    private static func needsQuotes(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if indicatorCharacters.contains(first) { return true }
        if last == ":" { return true }
        if text.contains(": ") || text.contains(" #") || text.contains(where: { $0.isNewline }) { return true }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return true }
        if reservedWords.contains(text.lowercased()) { return true }
        if looksLikeNumber(text) || looksLikeDate(text) { return true }
        return false
    }

    private static func looksLikeNumber(_ text: String) -> Bool {
        if Double(text) != nil { return true }
        let lowered = text.lowercased()
        if [".inf", "-.inf", "+.inf", ".nan"].contains(lowered) { return true }
        if lowered.hasPrefix("0x") || lowered.hasPrefix("0o") { return true }
        return false
    }

    private static func looksLikeDate(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count >= 10 else { return false }
        let pattern = "dddd-dd-dd"
        for (index, expected) in pattern.enumerated() {
            let character = characters[index]
            if expected == "d" ? !(character.isASCII && character.isNumber) : character != expected { return false }
        }
        return true
    }
}
