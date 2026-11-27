/**
 * File: JSONValue.swift
 * ---------------------
 * Layer: Core
 * Description: JSON read and written with the standard library alone, for answers of web services such as Notion's
 *              API: objects keep their keys' order, numbers keep the text they were written with.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

/// A JSON value. A number keeps its text as written, so that a value is copied without rounding and without the
/// floating-point printing that Embedded Swift lacks. An object keeps its members in order.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// A number as written (`42`, `-0.5`, `1e3`).
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public static func == (left: JSONValue, right: JSONValue) -> Bool {
        switch (left, right) {
        case (.null, .null): return true
        case (.bool(let leftValue), .bool(let rightValue)): return leftValue == rightValue
        case (.number(let leftValue), .number(let rightValue)): return leftValue == rightValue
        case (.string(let leftValue), .string(let rightValue)): return leftValue == rightValue
        case (.array(let leftValue), .array(let rightValue)): return leftValue == rightValue
        case (.object(let leftMembers), .object(let rightMembers)):
            guard leftMembers.count == rightMembers.count else { return false }
            for index in leftMembers.indices where leftMembers[index].key != rightMembers[index].key || leftMembers[index].value != rightMembers[index].value {
                return false
            }
            return true
        default: return false
        }
    }

    // MARK: Reading values

    /// The member named `key` of an object, `nil` for a missing member or another kind of value.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        for member in members where member.key == key { return member.value }
        return nil
    }

    /// The string, `nil` for another kind of value.
    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// The elements of an array, empty for another kind of value.
    public var elements: [JSONValue] {
        if case .array(let values) = self { return values }
        return []
    }

    /// The members of an object, empty for another kind of value.
    public var members: [(key: String, value: JSONValue)] {
        if case .object(let values) = self { return values }
        return []
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The number as written, `nil` for another kind of value.
    public var numberText: String? {
        if case .number(let text) = self { return text }
        return nil
    }

    /// The number when it is a whole number that fits an `Int`.
    public var integer: Int? {
        guard case .number(let text) = self else { return nil }
        return Int(text)
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: Writing

    /// The value as compact JSON text.
    public var text: String {
        var result = ""
        write(into: &result)
        return result
    }

    private func write(into result: inout String) {
        switch self {
        case .null: result += "null"
        case .bool(let value): result += value ? "true" : "false"
        case .number(let text): result += text
        case .string(let text): JSONValue.writeString(text, into: &result)
        case .array(let values):
            result += "["
            for (index, value) in values.enumerated() {
                if index > 0 { result += "," }
                value.write(into: &result)
            }
            result += "]"
        case .object(let members):
            result += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { result += "," }
                JSONValue.writeString(member.key, into: &result)
                result += ":"
                member.value.write(into: &result)
            }
            result += "}"
        }
    }

    private static func writeString(_ text: String, into result: inout String) {
        result += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    let digits: [String] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
                    result += "\\u00" + digits[Int(scalar.value >> 4)] + digits[Int(scalar.value & 0xF)]
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
    }

    // MARK: Reading text

    /// Why JSON text could not be read.
    public enum ParseError: Error, Equatable, Sendable {
        /// Something other than JSON at this byte offset.
        case unexpected(offset: Int)
        /// Nested deeper than the reader allows.
        case tooDeep
    }

    /// The JSON value of `bytes` (UTF-8 text), nested at most `maximumDepth` arrays and objects deep.
    public static func parse(_ bytes: [UInt8], maximumDepth: Int = 128) throws -> JSONValue {
        var reader = JSONReader(bytes: bytes, maximumDepth: maximumDepth)
        reader.skipSpace()
        let value = try reader.readValue(depth: 0)
        reader.skipSpace()
        guard reader.offset == bytes.count else { throw ParseError.unexpected(offset: reader.offset) }
        return value
    }

    /// The JSON value of `text`.
    public static func parse(_ text: String, maximumDepth: Int = 128) throws -> JSONValue {
        try parse(Array(text.utf8), maximumDepth: maximumDepth)
    }
}

/// Reads JSON text byte by byte.
private struct JSONReader {
    let bytes: [UInt8]
    let maximumDepth: Int
    var offset = 0

    init(bytes: [UInt8], maximumDepth: Int) {
        self.bytes = bytes
        self.maximumDepth = maximumDepth
    }

    mutating func skipSpace() {
        while offset < bytes.count, bytes[offset] == 0x20 || bytes[offset] == 0x0A || bytes[offset] == 0x0D || bytes[offset] == 0x09 {
            offset += 1
        }
    }

    private func failure() -> JSONValue.ParseError { .unexpected(offset: offset) }

    mutating func readValue(depth: Int) throws -> JSONValue {
        guard depth <= maximumDepth else { throw JSONValue.ParseError.tooDeep }
        guard offset < bytes.count else { throw failure() }
        switch bytes[offset] {
        case UInt8(ascii: "{"): return try readObject(depth: depth)
        case UInt8(ascii: "["): return try readArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try readString())
        case UInt8(ascii: "t"): try readWord("true"); return .bool(true)
        case UInt8(ascii: "f"): try readWord("false"); return .bool(false)
        case UInt8(ascii: "n"): try readWord("null"); return .null
        default: return .number(try readNumber())
        }
    }

    private mutating func readWord(_ word: String) throws {
        for byte in word.utf8 {
            guard offset < bytes.count, bytes[offset] == byte else { throw failure() }
            offset += 1
        }
    }

    private mutating func readObject(depth: Int) throws -> JSONValue {
        offset += 1
        var members: [(key: String, value: JSONValue)] = []
        skipSpace()
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
            offset += 1
            return .object(members)
        }
        while true {
            skipSpace()
            guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else { throw failure() }
            let key = try readString()
            skipSpace()
            guard offset < bytes.count, bytes[offset] == UInt8(ascii: ":") else { throw failure() }
            offset += 1
            skipSpace()
            members.append((key, try readValue(depth: depth + 1)))
            skipSpace()
            guard offset < bytes.count else { throw failure() }
            if bytes[offset] == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            guard bytes[offset] == UInt8(ascii: "}") else { throw failure() }
            offset += 1
            return .object(members)
        }
    }

    private mutating func readArray(depth: Int) throws -> JSONValue {
        offset += 1
        var values: [JSONValue] = []
        skipSpace()
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
            offset += 1
            return .array(values)
        }
        while true {
            skipSpace()
            values.append(try readValue(depth: depth + 1))
            skipSpace()
            guard offset < bytes.count else { throw failure() }
            if bytes[offset] == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            guard bytes[offset] == UInt8(ascii: "]") else { throw failure() }
            offset += 1
            return .array(values)
        }
    }

    private mutating func readNumber() throws -> String {
        let start = offset
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "-") { offset += 1 }
        let digitsStart = offset
        while offset < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[offset]) { offset += 1 }
        guard offset > digitsStart else { throw failure() }
        if offset < bytes.count, bytes[offset] == UInt8(ascii: ".") {
            offset += 1
            let fractionStart = offset
            while offset < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[offset]) { offset += 1 }
            guard offset > fractionStart else { throw failure() }
        }
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "e") || bytes[offset] == UInt8(ascii: "E") {
            offset += 1
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "+") || bytes[offset] == UInt8(ascii: "-") { offset += 1 }
            let exponentStart = offset
            while offset < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[offset]) { offset += 1 }
            guard offset > exponentStart else { throw failure() }
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private mutating func readHexQuad() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw failure() }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = TextBytes.hexValue(bytes[offset]) else { throw failure() }
            value = value << 4 | UInt32(digit)
            offset += 1
        }
        return value
    }

    private mutating func readString() throws -> String {
        offset += 1
        var utf8: [UInt8] = []
        while true {
            guard offset < bytes.count else { throw failure() }
            let byte = bytes[offset]
            if byte == UInt8(ascii: "\"") {
                offset += 1
                return String(decoding: utf8, as: UTF8.self)
            }
            guard byte >= 0x20 else { throw failure() }
            if byte != UInt8(ascii: "\\") {
                utf8.append(byte)
                offset += 1
                continue
            }
            offset += 1
            guard offset < bytes.count else { throw failure() }
            let escape = bytes[offset]
            offset += 1
            switch escape {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escape)
            case UInt8(ascii: "b"): utf8.append(0x08)
            case UInt8(ascii: "f"): utf8.append(0x0C)
            case UInt8(ascii: "n"): utf8.append(0x0A)
            case UInt8(ascii: "r"): utf8.append(0x0D)
            case UInt8(ascii: "t"): utf8.append(0x09)
            case UInt8(ascii: "u"):
                var value = try readHexQuad()
                if (0xD800...0xDBFF).contains(value), offset + 6 <= bytes.count, bytes[offset] == UInt8(ascii: "\\"),
                    bytes[offset + 1] == UInt8(ascii: "u")
                {
                    let saved = offset
                    offset += 2
                    let low = try readHexQuad()
                    if (0xDC00...0xDFFF).contains(low) {
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        offset = saved
                    }
                }
                let scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
                utf8.append(contentsOf: String(Character(scalar)).utf8)
            default:
                throw failure()
            }
        }
    }
}
