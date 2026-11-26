/**
 * File: MarkdownWriter.swift
 * --------------------------
 * Layer: Core
 * Description: Writes the blocks of a note as Obsidian Markdown: text escaped so that it reads as written, styles
 *              split at line breaks and never left with spaces inside their delimiters, callouts, math, code, tables
 *              and nested lists in the form Obsidian and Graphite read.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

/// Obsidian Markdown written from blocks.
///
/// Blocks are separated by one empty line. Line breaks inside a paragraph are written as two spaces and a line end,
/// and two line breaks in a row start a new paragraph, as an empty line in Markdown does. List items nest by four
/// spaces (more for numbers of three digits). Text is escaped where Markdown or Obsidian would read it as syntax: `*`,
/// `\` before punctuation, `` ` ``, `$` (math), `_` at the edge of a word, `~~`, `==`, `%%`, `[[`, `](`, `<` before a
/// tag name, `#` before a tag name (an Obsidian tag), and at the start of a line `#`, `>`, `-`, `+`, a number and a dot,
/// and rules.
public enum MarkdownWriter {
    /// The Markdown of `blocks`, ending with a line end, or empty when they write nothing.
    public static func markdown(for blocks: [MarkdownBlock]) -> String {
        let text = render(blocks)
        return text.isEmpty ? "" : text + "\n"
    }

    /// The Markdown of `blocks`, without a final line end.
    static func render(_ blocks: [MarkdownBlock]) -> String {
        blocks.compactMap(render).joined(separator: "\n\n")
    }

    private static func render(_ block: MarkdownBlock) -> String? {
        switch block {
        case .paragraph(let inlines):
            return renderParagraph(inlines)
        case .heading(let level, let inlines):
            let text = renderLine(inlines, context: InlineContext(lineBreak: " "))
            guard !text.isEmpty else { return nil }
            return String(repeating: "#", count: min(max(level, 1), 6)) + " " + text
        case .bulletList(let items):
            return renderList(items) { _ in "-" }
        case .numberedList(let start, let items):
            return renderList(items) { index in "\(start + index)." }
        case .quote(let blocks):
            let body = render(blocks)
            guard !body.isEmpty else { return nil }
            return prefixLines(body, with: ">")
        case .callout(let type, let title, let folding, let body):
            var header = "> [!\(type)]"
            switch folding {
            case .notFoldable: break
            case .folded: header += "-"
            case .unfolded: header += "+"
            }
            let titleText = renderLine(title, context: InlineContext(lineBreak: "<br>"))
            if !titleText.isEmpty { header += " " + titleText }
            let bodyText = render(body)
            return bodyText.isEmpty ? header : header + "\n" + prefixLines(bodyText, with: ">")
        case .codeBlock(let language, let code):
            var trimmed = code
            while trimmed.hasSuffix("\n") { trimmed.removeLast() }
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: trimmed) + 1))
            return fence + language + "\n" + trimmed + "\n" + fence
        case .mathBlock(let tex):
            let cleaned = cleanedTeX(tex, isInline: false)
            guard !cleaned.isEmpty else { return nil }
            return "$$\n" + cleaned + "\n$$"
        case .thematicBreak:
            return "---"
        case .table(let header, let rows):
            return renderTable(header: header, rows: rows)
        }
    }

    // MARK: Paragraphs

    private static func renderParagraph(_ inlines: [MarkdownInline]) -> String? {
        let normalized = MarkdownInlineNormalizer.normalize(inlines)
        var lines: [[MarkdownInline]] = [[]]
        for inline in normalized {
            if inline == .lineBreak {
                lines.append([])
            } else {
                lines[lines.count - 1].append(inline)
            }
        }
        let rendered = lines.map { escapeLineStart(renderLine($0, context: InlineContext(lineBreak: " "))) }
        // An empty line between two lines (two line breaks in a row) starts a new paragraph.
        var paragraphs: [[String]] = [[]]
        for line in rendered {
            if line.isEmpty {
                if !(paragraphs.last?.isEmpty ?? true) { paragraphs.append([]) }
            } else {
                paragraphs[paragraphs.count - 1].append(line)
            }
        }
        let text = paragraphs.filter { !$0.isEmpty }.map { $0.joined(separator: "  \n") }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// Inline content written on one line, trimmed.
    static func renderLine(_ inlines: [MarkdownInline], context: InlineContext) -> String {
        var normalized = MarkdownInlineNormalizer.normalize(inlines)
        while let first = normalized.first, first == .lineBreak || first == .text(" ") { normalized.removeFirst() }
        while let last = normalized.last, last == .lineBreak || last == .text(" ") { normalized.removeLast() }
        let text = renderInlines(normalized, context: context)
        return trimmed(text)
    }

    // MARK: Lists

    private static func renderList(_ items: [MarkdownListItem], marker: (Int) -> String) -> String? {
        var lines: [String] = []
        var number = 0
        for item in items {
            let rendered: [(block: MarkdownBlock, text: String)] = item.blocks.compactMap { block in
                render(block).map { (block, $0) }
            }
            guard !rendered.isEmpty || item.checkbox != nil else { continue }
            var itemMarker = marker(number)
            number += 1
            if let checked = item.checkbox { itemMarker += checked ? " [x]" : " [ ]" }
            let indent = String(repeating: " ", count: max(4, marker(number - 1).count + 1))
            var itemText = ""
            for (index, part) in rendered.enumerated() {
                if index > 0 {
                    switch part.block {
                    case .bulletList, .numberedList: itemText += "\n"
                    default: itemText += "\n\n"
                    }
                }
                itemText += part.text
            }
            var itemLines = itemText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if itemLines.isEmpty { itemLines = [""] }
            let first = itemLines[0].isEmpty ? itemMarker : itemMarker + " " + itemLines[0]
            lines.append(first)
            for line in itemLines.dropFirst() {
                lines.append(line.isEmpty ? "" : indent + line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Tables

    private static func renderTable(header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> String? {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return nil }
        let context = InlineContext(lineBreak: "<br>", isInTableCell: true)
        func line(_ cells: [[MarkdownInline]]) -> String {
            let texts = (0..<columnCount).map { index in index < cells.count ? renderLine(cells[index], context: context) : "" }
            return "| " + texts.joined(separator: " | ") + " |"
        }
        var lines = [line(header), "|" + String(repeating: " --- |", count: columnCount)]
        lines.append(contentsOf: rows.map(line))
        return lines.joined(separator: "\n")
    }

    // MARK: Inline content

    struct InlineContext {
        /// What a line break is written as: a space in headings, `<br>` in callout titles and table cells.
        var lineBreak: String
        var isInTableCell = false
    }

    private static func renderInlines(_ inlines: [MarkdownInline], context: InlineContext) -> String {
        var result = ""
        for (index, inline) in inlines.enumerated() {
            let following: Character? = index + 1 < inlines.count ? firstCharacter(of: inlines[index + 1]) : nil
            result += renderInline(inline, context: context, followedBy: following, precededBy: result.last)
        }
        return result
    }

    private static func firstCharacter(of inline: MarkdownInline) -> Character? {
        switch inline {
        case .text(let text): return text.first
        case .lineBreak: return " "
        default: return "*"
        }
    }

    private static func renderInline(_ inline: MarkdownInline, context: InlineContext, followedBy following: Character?,
                                     precededBy preceding: Character?) -> String {
        switch inline {
        case .text(let text):
            return escapeText(text, context: context, followedBy: following, precededBy: preceding)
        case .strong(let children):
            return wrap(children, opening: "**", closing: "**", context: context)
        case .emphasis(let children):
            // `_`, as Obsidian writes it, unless a letter or digit touches it, where only `*` works.
            let touchesWord = [preceding, following].contains { $0.map { $0.isLetter || $0.isNumber } ?? false }
            let delimiter = touchesWord ? "*" : "_"
            return wrap(children, opening: delimiter, closing: delimiter, context: context)
        case .strikethrough(let children):
            return wrap(children, opening: "~~", closing: "~~", context: context)
        case .highlight(let children):
            return wrap(children, opening: "==", closing: "==", context: context)
        case .underline(let children):
            return wrap(children, opening: "<u>", closing: "</u>", context: context)
        case .code(let code):
            let flat = code.replacingOccurrences(of: "\n", with: " ")
            guard !flat.isEmpty else { return "" }
            let fence = String(repeating: "`", count: longestRun(of: "`", in: flat) + 1)
            let padding = flat.hasPrefix("`") || flat.hasSuffix("`") ? " " : ""
            let escaped = context.isInTableCell ? flat.replacingOccurrences(of: "|", with: "\\|") : flat
            return fence + padding + escaped + padding + fence
        case .math(let tex):
            let cleaned = cleanedTeX(tex, isInline: true)
            guard !cleaned.isEmpty else { return "" }
            return "$" + (context.isInTableCell ? cleaned.replacingOccurrences(of: "|", with: "\\|") : cleaned) + "$"
        case .link(let destination, let label):
            let labelText = trimmed(renderInlines(MarkdownInlineNormalizer.normalize(label), context: context))
            let plainLabel = MarkdownInlineNormalizer.plainText(of: label).trimmingCharacters(in: .whitespaces)
            let isWebAddress = destination.hasPrefix("http://") || destination.hasPrefix("https://")
            if labelText.isEmpty || (isWebAddress && plainLabel == destination) {
                return isWebAddress ? destination : "<\(destination)>"
            }
            return "[" + labelText + "](" + linkDestination(destination) + ")"
        case .wikiLink(let target, let label, let isEmbed):
            var text = isEmbed ? "![[" : "[["
            text += target
            if let label, !label.isEmpty, label != target {
                let cleanedLabel = label.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                    .replacingOccurrences(of: "|", with: "")
                text += (context.isInTableCell ? "\\|" : "|") + cleanedLabel
            }
            return text + "]]"
        case .image(let source, let alternativeText):
            let alternative = alternativeText.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            return "![" + alternative + "](" + linkDestination(source) + ")"
        case .lineBreak:
            return context.lineBreak
        case .markdown(let markdown):
            return markdown
        }
    }

    private static func wrap(_ children: [MarkdownInline], opening: String, closing: String, context: InlineContext) -> String {
        let inner = renderInlines(children, context: context)
        let leading = inner.prefix(while: { $0 == " " })
        let trailing = inner.reversed().prefix(while: { $0 == " " })
        guard leading.count < inner.count else { return inner }
        let core = inner.dropFirst(leading.count).dropLast(trailing.count)
        return String(leading) + opening + core + closing + String(trailing)
    }

    private static func linkDestination(_ destination: String) -> String {
        if destination.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" }) {
            return "<" + destination.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
        }
        return destination
    }

    // MARK: Escaping

    private static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    static func escapeText(_ text: String, context: InlineContext, followedBy following: Character?,
                           precededBy preceding: Character?) -> String {
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : following
            let previous = index > 0 ? characters[index - 1] : preceding
            switch character {
            case "\\":
                result += next.map { asciiPunctuation.contains($0) } ?? true ? "\\\\" : "\\"
            case "*", "`", "$":
                result += "\\" + String(character)
            case "_":
                let isWordInside = (previous.map { $0.isLetter || $0.isNumber } ?? false)
                    && (next.map { $0.isLetter || $0.isNumber } ?? false)
                result += isWordInside ? "_" : "\\_"
            case "~", "=", "%":
                result += next == character ? "\\" + String(character) : String(character)
            case "[":
                result += next == "[" ? "\\[" : "["
            case "]":
                result += next == "(" || next == "]" ? "\\]" : "]"
            case "<":
                let opensTag = next.map { $0.isASCII && ($0.isLetter || $0 == "/" || $0 == "!" || $0 == "?") } ?? false
                result += opensTag ? "\\<" : "<"
            case "#":
                result += startsTag(characters, after: index, following: following) ? "\\#" : "#"
            case "|":
                result += context.isInTableCell ? "\\|" : "|"
            default:
                result.append(character)
            }
        }
        return result
    }

    /// Whether the `#` at `index` starts an Obsidian tag: digits, then a letter, `-`, `_`, `/` or a character beyond
    /// ASCII.
    private static func startsTag(_ characters: [Character], after index: Int, following: Character?) -> Bool {
        var position = index + 1
        while position < characters.count, characters[position].isASCII, characters[position].isNumber {
            position += 1
        }
        let next = position < characters.count ? characters[position] : (position == index + 1 ? following : nil)
        guard let next else { return false }
        if !next.isASCII { return !next.isWhitespace }
        return next.isLetter || next == "-" || next == "_" || next == "/"
    }

    /// `line` with a backslash before what Markdown would read as the start of a block.
    static func escapeLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        let afterFirst = line.dropFirst()
        switch first {
        case "#":
            let hashes = line.prefix(while: { $0 == "#" })
            let rest = line.dropFirst(hashes.count)
            return hashes.count <= 6 && (rest.isEmpty || rest.first == " ") ? "\\" + line : line
        case ">":
            return "\\" + line
        case "-", "+":
            if afterFirst.isEmpty || afterFirst.first == " " { return "\\" + line }
            if first == "-", line.allSatisfy({ $0 == "-" || $0 == " " }), line.filter({ $0 == "-" }).count >= 3 {
                return "\\" + line
            }
            return line
        case "=":
            return line.allSatisfy({ $0 == "=" || $0 == " " }) ? "\\" + line : line
        default:
            let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, digits.count <= 9 else { return line }
            let rest = line.dropFirst(digits.count)
            if let marker = rest.first, marker == "." || marker == ")" {
                let afterMarker = rest.dropFirst()
                if afterMarker.isEmpty || afterMarker.first == " " {
                    return digits + "\\" + rest
                }
            }
            return line
        }
    }

    // MARK: Helpers

    /// TeX trimmed of the space and line breaks (`\\`, `\ `) at its ends, without empty lines (which end a math block
    /// in Obsidian) and without spaces at line ends. Inline math is on one line.
    static func cleanedTeX(_ tex: String, isInline: Bool) -> String {
        var scalars = Substring(tex)
        while true {
            let before = scalars.count
            scalars = scalars.drop(while: { $0.isWhitespace })
            if scalars.hasPrefix("\\\\") || scalars.hasPrefix("\\ ") { scalars = scalars.dropFirst(2) }
            if scalars.count == before { break }
        }
        while let last = scalars.last, last.isWhitespace || last == "\\" { scalars = scalars.dropLast() }
        let lines = scalars.split(whereSeparator: { $0.isNewline }).map { line in
            String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.joined(separator: isInline ? " " : "\n")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    private static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for scalar in text {
            if scalar == character {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func prefixLines(_ text: String, with prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? prefix : prefix + " " + $0 }
            .joined(separator: "\n")
    }
}

/// Inline content put in the shape Markdown can write: a style inside the same style is dropped, styles next to each
/// other merge, a style holding a line break is split around it, and texts next to each other join. Runs of spaces
/// become one, as they show in HTML.
public enum MarkdownInlineNormalizer {
    /// `inlines` put in the shape Markdown can write.
    public static func normalize(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        mergeTexts(merge(inlines.flatMap { normalize($0, insideStyles: []) }))
    }

    private enum Style: Hashable {
        case strong, emphasis, strikethrough, highlight, underline
    }

    private static func style(of inline: MarkdownInline) -> (Style, [MarkdownInline])? {
        switch inline {
        case .strong(let children): return (.strong, children)
        case .emphasis(let children): return (.emphasis, children)
        case .strikethrough(let children): return (.strikethrough, children)
        case .highlight(let children): return (.highlight, children)
        case .underline(let children): return (.underline, children)
        default: return nil
        }
    }

    private static func make(_ style: Style, _ children: [MarkdownInline]) -> MarkdownInline {
        switch style {
        case .strong: return .strong(children)
        case .emphasis: return .emphasis(children)
        case .strikethrough: return .strikethrough(children)
        case .highlight: return .highlight(children)
        case .underline: return .underline(children)
        }
    }

    private static func normalize(_ inline: MarkdownInline, insideStyles: Set<Style>) -> [MarkdownInline] {
        switch inline {
        case .text(let text):
            let collapsed = collapseSpaces(text)
            return collapsed.isEmpty ? [] : [.text(collapsed)]
        case .link(let destination, let label):
            return [.link(destination: destination, label: mergeTexts(merge(label.flatMap { normalize($0, insideStyles: insideStyles) })))]
        default:
            guard let (style, children) = style(of: inline) else { return [inline] }
            let inner = mergeTexts(merge(children.flatMap { normalize($0, insideStyles: insideStyles.union([style])) }))
            if insideStyles.contains(style) { return inner }
            // Split around line breaks: a style cannot hold one in Markdown.
            var pieces: [MarkdownInline] = []
            var current: [MarkdownInline] = []
            for child in inner {
                if child == .lineBreak {
                    if !current.isEmpty { pieces.append(make(style, current)) }
                    pieces.append(.lineBreak)
                    current = []
                } else {
                    current.append(child)
                }
            }
            if !current.isEmpty { pieces.append(make(style, current)) }
            return pieces
        }
    }

    /// Joins a style with the same style right after it, or after only spaces.
    private static func merge(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for inline in inlines {
            if let (style, children) = style(of: inline), let last = result.last {
                if let (lastStyle, lastChildren) = self.style(of: last), lastStyle == style {
                    result[result.count - 1] = make(style, mergeTexts(merge(lastChildren + children)))
                    continue
                }
                if case .text(let spaces) = last, spaces.allSatisfy({ $0 == " " }), result.count >= 2,
                    let (beforeStyle, beforeChildren) = self.style(of: result[result.count - 2]), beforeStyle == style
                {
                    result.removeLast()
                    result[result.count - 1] = make(style, mergeTexts(merge(beforeChildren + [.text(spaces)] + children)))
                    continue
                }
            }
            result.append(inline)
        }
        return result
    }

    private static func mergeTexts(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for inline in inlines {
            if case .text(let text) = inline, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(collapseSpaces(previous + text))
            } else {
                result.append(inline)
            }
        }
        return result
    }

    private static func collapseSpaces(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            let isSpace = character == " " || character == "\t"
            if isSpace {
                if !lastWasSpace { result.append(" ") }
            } else {
                result.append(character)
            }
            lastWasSpace = isSpace
        }
        return result
    }

    /// Whether inline content writes nothing: no text but spaces and line breaks.
    public static func isBlank(_ inlines: [MarkdownInline]) -> Bool {
        inlines.allSatisfy { inline in
            switch inline {
            case .text(let text): return text.allSatisfy(\.isWhitespace)
            case .lineBreak: return true
            case .strong(let children), .emphasis(let children), .strikethrough(let children), .highlight(let children),
                .underline(let children):
                return isBlank(children)
            default: return false
            }
        }
    }

    /// The text of inline content without its styles.
    public static func plainText(of inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text), .code(let text), .math(let text), .markdown(let text): return text
            case .strong(let children), .emphasis(let children), .strikethrough(let children),
                .highlight(let children), .underline(let children):
                return plainText(of: children)
            case .link(_, let label): return plainText(of: label)
            case .wikiLink(let target, let label, _): return label ?? target
            case .image(_, let alternativeText): return alternativeText
            case .lineBreak: return " "
            }
        }.joined()
    }
}
