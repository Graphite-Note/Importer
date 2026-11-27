/**
 * File: NotionFormulaConverter.swift
 * ----------------------------------
 * Layer: Notion
 * Description: Notion's formulas in the formula language of Obsidian Bases: read into a tree, then written with
 *              Bases' functions, methods and operators, or refused with the function Bases lacks. The function table
 *              follows Obsidian Importer's formula-converter.ts (MIT, see OBSIDIAN-IMPORTER-LICENSE), widened to the
 *              functions Bases has since gained.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import ImporterCore

/// Converts Notion formulas (formula 2.0) to Bases formulas.
public enum NotionFormulaConverter {
    /// Why a formula cannot be written in Bases.
    public enum Failure: Error, Equatable, Sendable {
        /// The formula calls a function Bases has no counterpart for.
        case unsupportedFunction(String)
        /// The formula could not be read.
        case unreadable
    }

    /// The Bases formula of `expression`. Properties are named `prop("Name")`, or as the API writes them,
    /// `{{notion:block_property:<id>:…}}`, which `propertyNames` maps from identifier to name. A property that is itself
    /// a converted formula is read as `formula["Name"]`, the others as `note["Name"]`.
    public static func convert(_ expression: String, propertyNames: [String: String] = [:], formulaNames: Set<String> = []) throws -> String {
        var tokens = try tokenize(replacingPlaceholders(expression, propertyNames: propertyNames))
        tokens.append(.end)
        var parser = Parser(tokens: tokens)
        let tree = try parser.parseExpression()
        guard parser.current == .end else { throw Failure.unreadable }
        return try write(tree, formulaNames: formulaNames)
    }

    // MARK: Placeholders

    static func replacingPlaceholders(_ expression: String, propertyNames: [String: String]) -> String {
        var result = ""
        var rest = Substring(expression)
        while let start = rest.range(ofText: "{{notion:block_property:") {
            result += rest[rest.startIndex..<start.lowerBound]
            let afterPrefix = rest[start.upperBound...]
            guard let close = afterPrefix.range(ofText: "}}") else { break }
            let identifier = afterPrefix[afterPrefix.startIndex..<close.lowerBound].pieces(separatedBy: ":").first ?? ""
            let name = propertyNames[identifier] ?? propertyNames[identifier.percentDecoded ?? identifier] ?? identifier
            result += "prop(\"" + name.replacingEvery("\"", with: "\\\"") + "\")"
            rest = afterPrefix[close.upperBound...]
        }
        return result + rest
    }

    // MARK: Tokens

    enum Token: Equatable {
        case number(String)
        case string(String)
        case name(String)
        case symbol(String)
        case end
    }

    static func tokenize(_ text: String) throws -> [Token] {
        let scalars = Array(text.unicodeScalars)
        var tokens: [Token] = []
        var index = 0
        func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.isSpaceOrLineBreak { index += 1; continue }
            if ("0"..."9").contains(scalar) || (scalar == "." && index + 1 < scalars.count && ("0"..."9").contains(scalars[index + 1])) {
                var end = index
                while end < scalars.count, ("0"..."9").contains(scalars[end]) || scalars[end] == "." { end += 1 }
                tokens.append(.number(String(String.UnicodeScalarView(scalars[index..<end]))))
                index = end
                continue
            }
            if scalar == "\"" || scalar == "'" {
                var value = String.UnicodeScalarView()
                var end = index + 1
                while end < scalars.count, scalars[end] != scalar {
                    if scalars[end] == "\\", end + 1 < scalars.count { end += 1 }
                    value.append(scalars[end])
                    end += 1
                }
                guard end < scalars.count else { throw Failure.unreadable }
                tokens.append(.string(String(value)))
                index = end + 1
                continue
            }
            if isNameScalar(scalar) {
                var end = index
                while end < scalars.count, isNameScalar(scalars[end]) { end += 1 }
                tokens.append(.name(String(String.UnicodeScalarView(scalars[index..<end]))))
                index = end
                continue
            }
            let pair = index + 1 < scalars.count ? String(String.UnicodeScalarView(scalars[index...index + 1])) : ""
            if ["==", "!=", ">=", "<=", "&&", "||"].contains(pair) {
                tokens.append(.symbol(pair))
                index += 2
                continue
            }
            let single = String(Character(scalar))
            guard "+-*/%^()[],.<>!?:".contains(text: single) else { throw Failure.unreadable }
            tokens.append(.symbol(single))
            index += 1
        }
        return tokens
    }

    // MARK: Tree

    indirect enum Node: Equatable {
        case number(String)
        case string(String)
        case boolean(Bool)
        case property(String)
        case variable(String)
        case list([Node])
        case call(String, [Node])
        case method(Node, String, [Node])
        case unary(String, Node)
        case binary(String, Node, Node)
        case conditional(Node, Node, Node)
    }

    struct Parser {
        var tokens: [Token]
        var position = 0

        var current: Token { tokens[position] }

        mutating func advance() { if position < tokens.count - 1 { position += 1 } }

        mutating func expect(_ symbol: String) throws {
            guard current == .symbol(symbol) else { throw Failure.unreadable }
            advance()
        }

        mutating func parseExpression() throws -> Node {
            let condition = try parseBinary(level: 0)
            if current == .symbol("?") {
                advance()
                let whenTrue = try parseExpression()
                try expect(":")
                let whenFalse = try parseExpression()
                return .conditional(condition, whenTrue, whenFalse)
            }
            return condition
        }

        /// Operators from the loosest to the tightest; `^` is the tightest binary operator.
        static let levels: [[String]] = [["or", "||"], ["and", "&&"], ["==", "!="], [">", "<", ">=", "<="], ["+", "-"], ["*", "/", "%"], ["^"]]

        func operatorAt(level: Int) -> String? {
            switch current {
            case .symbol(let symbol) where Parser.levels[level].contains(symbol): return symbol
            case .name(let word) where Parser.levels[level].contains(word): return word
            default: return nil
            }
        }

        mutating func parseBinary(level: Int) throws -> Node {
            guard level < Parser.levels.count else { return try parseUnary() }
            var left = try parseBinary(level: level + 1)
            while let symbol = operatorAt(level: level) {
                advance()
                // `^` binds to the right.
                let right = symbol == "^" ? try parseBinary(level: level) : try parseBinary(level: level + 1)
                left = .binary(symbol, left, right)
            }
            return left
        }

        mutating func parseUnary() throws -> Node {
            if current == .symbol("-") { advance(); return .unary("-", try parseUnary()) }
            if current == .symbol("!") || current == .name("not") { advance(); return .unary("!", try parseUnary()) }
            return try parsePostfix(try parsePrimary())
        }

        mutating func parseArguments() throws -> [Node] {
            try expect("(")
            var arguments: [Node] = []
            if current == .symbol(")") { advance(); return arguments }
            while true {
                arguments.append(try parseExpression())
                if current == .symbol(",") { advance(); continue }
                try expect(")")
                return arguments
            }
        }

        mutating func parsePostfix(_ base: Node) throws -> Node {
            var node = base
            while current == .symbol(".") {
                advance()
                guard case .name(let name) = current else { throw Failure.unreadable }
                advance()
                let arguments = current == .symbol("(") ? try parseArguments() : []
                node = .method(node, name, arguments)
            }
            return node
        }

        mutating func parsePrimary() throws -> Node {
            switch current {
            case .number(let text): advance(); return .number(text)
            case .string(let text): advance(); return .string(text)
            case .symbol("("):
                advance()
                let inner = try parseExpression()
                try expect(")")
                return inner
            case .symbol("["):
                advance()
                var elements: [Node] = []
                if current == .symbol("]") { advance(); return .list(elements) }
                while true {
                    elements.append(try parseExpression())
                    if current == .symbol(",") { advance(); continue }
                    try expect("]")
                    return .list(elements)
                }
            case .name(let name):
                advance()
                if name == "true" { return .boolean(true) }
                if name == "false" { return .boolean(false) }
                guard current == .symbol("(") else { return .variable(name) }
                let arguments = try parseArguments()
                if name == "prop", arguments.count == 1, case .string(let property) = arguments[0] { return .property(property) }
                return .call(name, arguments)
            default:
                throw Failure.unreadable
            }
        }
    }

    // MARK: Writing Bases

    /// Notion functions written as a Bases global function of another name, or the same.
    static let globals: [String: String] = [
        "if": "if", "now": "now", "today": "today", "toNumber": "number", "parseDate": "date", "max": "max", "min": "min",
    ]
    /// Notion functions written as a method of their first argument: `lower(x)` as `x.lower()`.
    static let methods: [String: String] = [
        "format": "toString", "contains": "contains", "lower": "lower", "upper": "upper", "replace": "replace",
        "substring": "slice", "slice": "slice", "reverse": "reverse", "sort": "sort", "unique": "unique", "flat": "flat",
        "join": "join", "includes": "contains", "map": "map", "filter": "filter", "abs": "abs", "ceil": "ceil",
        "floor": "floor", "round": "round", "formatDate": "format", "trim": "trim", "split": "split", "repeat": "repeat",
        "startsWith": "startsWith", "endsWith": "endsWith",
    ]
    /// Notion functions written as a field of their argument: `year(d)` as `d.year`.
    static let fields: [String: String] = [
        "length": "length", "date": "day", "year": "year", "month": "month", "hour": "hour", "minute": "minute",
    ]
    /// Notion functions written as an operator between their two arguments.
    static let operators: [String: String] = [
        "add": "+", "subtract": "-", "multiply": "*", "divide": "/", "mod": "%", "equal": "==", "unequal": "!=",
    ]
    /// Notion methods (`x.length()`) whose Bases counterpart is a field.
    static let fieldMethods: Set<String> = ["length", "year", "month", "hour", "minute"]

    static func write(_ node: Node, formulaNames: Set<String>) throws -> String {
        func each(_ nodes: [Node]) throws -> [String] { try nodes.map { try write($0, formulaNames: formulaNames) } }
        func grouped(_ node: Node) throws -> String {
            switch node {
            case .binary, .conditional, .unary: return "(" + (try write(node, formulaNames: formulaNames)) + ")"
            default: return try write(node, formulaNames: formulaNames)
            }
        }
        switch node {
        case .number(let text): return text
        case .string(let text): return "\"" + text.replacingEvery("\\", with: "\\\\").replacingEvery("\"", with: "\\\"") + "\""
        case .boolean(let value): return value ? "true" : "false"
        case .property(let name):
            let quoted = "\"" + name.replacingEvery("\"", with: "\\\"") + "\""
            return (formulaNames.contains(name) ? "formula[" : "note[") + quoted + "]"
        case .variable(let name):
            switch name {
            case "current": return "value"
            case "index": return "index"
            default: throw Failure.unsupportedFunction(name)
            }
        case .list(let elements): return "[" + (try each(elements)).joined(separator: ", ") + "]"
        case .unary(let symbol, let operand): return symbol + (try grouped(operand))
        case .binary(let symbol, let left, let right):
            if symbol == "^" { throw Failure.unsupportedFunction("pow") }
            let written = ["and": "&&", "or": "||"][symbol] ?? symbol
            return (try grouped(left)) + " " + written + " " + (try grouped(right))
        case .conditional(let condition, let whenTrue, let whenFalse):
            return "if(" + (try each([condition, whenTrue, whenFalse])).joined(separator: ", ") + ")"
        case .method(let receiver, let name, let arguments):
            return try writeCall(name, [receiver] + arguments, formulaNames: formulaNames, asMethod: true)
        case .call(let name, let arguments):
            return try writeCall(name, arguments, formulaNames: formulaNames, asMethod: false)
        }
    }

    private static func writeCall(_ name: String, _ arguments: [Node], formulaNames: Set<String>, asMethod: Bool) throws -> String {
        func each(_ nodes: [Node]) throws -> [String] { try nodes.map { try write($0, formulaNames: formulaNames) } }
        func receiver(_ node: Node) throws -> String {
            switch node {
            case .binary, .conditional, .unary: return "(" + (try write(node, formulaNames: formulaNames)) + ")"
            default: return try write(node, formulaNames: formulaNames)
            }
        }
        if !asMethod, let global = globals[name] { return global + "(" + (try each(arguments)).joined(separator: ", ") + ")" }
        if ["sum", "mean", "median"].contains(name), !arguments.isEmpty {
            if asMethod { return (try receiver(arguments[0])) + ".flat()." + name + "()" }
            return "[" + (try each(arguments)).joined(separator: ", ") + "].flat()." + name + "()"
        }
        if name == "empty", arguments.count == 1 { return (try receiver(arguments[0])) + ".isEmpty()" }
        if (fields[name] != nil && !asMethod) || (asMethod && fieldMethods.contains(name)), arguments.count == 1 {
            return (try receiver(arguments[0])) + "." + (fields[name] ?? name)
        }
        if let method = methods[name], let first = arguments.first {
            return (try receiver(first)) + "." + method + "(" + (try each(Array(arguments.dropFirst()))).joined(separator: ", ") + ")"
        }
        if let symbol = operators[name], arguments.count == 2 {
            return (try receiver(arguments[0])) + " " + symbol + " " + (try receiver(arguments[1]))
        }
        switch (name, arguments.count) {
        case ("at", 2): return (try receiver(arguments[0])) + "[" + (try write(arguments[1], formulaNames: formulaNames)) + "]"
        case ("first", 1): return (try receiver(arguments[0])) + "[0]"
        case ("last", 1):
            let list = try receiver(arguments[0])
            return list + "[" + list + ".length - 1]"
        case ("dateAdd", 3), ("dateSubtract", 3):
            guard case .string(let unit) = arguments[2] else { throw Failure.unsupportedFunction(name) }
            let symbol = name == "dateAdd" ? " + " : " - "
            let amount: String
            if case .number(let text) = arguments[1] {
                amount = "\"" + text + " " + unit + "\""
            } else {
                amount = "(" + (try write(arguments[1], formulaNames: formulaNames)) + " + \" " + unit + "\")"
            }
            return (try receiver(arguments[0])) + symbol + amount
        case ("test", 2):
            guard case .string(let pattern) = arguments[1] else { throw Failure.unsupportedFunction(name) }
            return "/" + pattern.replacingEvery("/", with: "\\/") + "/.matches(" + (try write(arguments[0], formulaNames: formulaNames)) + ")"
        default:
            throw Failure.unsupportedFunction(name)
        }
    }
}
