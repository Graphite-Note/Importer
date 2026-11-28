/**
 * File: MarkdownWriter.swift
 * --------------------------
 * Layer: Core
 * Description: Writes the blocks of a note as Obsidian Markdown: text escaped so that it reads as written, styles
 *              split at line breaks and never left with spaces inside their delimiters, callouts, math, code, tables
 *              and nested lists in the form Obsidian and Graphite read.
 *
 * Authors: Bahey Shalash
 * Version: 0.4
 * Date: 28/11/2026
 */

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
        var rendered: [(block: MarkdownBlock, text: String)] = blocks.compactMap { block in render(block).map { (block, $0) } }
        // A note's text that starts with `---` has it read as the start of its properties: a rule there is `***`.
        if case .thematicBreak? = rendered.first?.block { rendered[0].text = "***" }
        let text = rendered.map { $0.text }.joined(separator: "\n\n")
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
        var lineContext = context
        lineContext.escapesDollars = dollarsCouldPair(normalized)
        let text = renderInlines(normalized, context: lineContext)
        return trimmed(text)
    }

    /// Whether two `$` of a line could pair into inline math as Obsidian reads it: one not followed by a space, then a
    /// later one not preceded by a space. Only then is a `$` of the text escaped, so that prices stay as written.
    static func dollarsCouldPair(_ inlines: [MarkdownInline]) -> Bool {
        let text = Array(dollarText(of: inlines))
        var hasOpener = false
        for (index, character) in text.enumerated() where character == "$" {
            if hasOpener, index > 0, !text[index - 1].isWhitespace { return true }
            if index + 1 < text.count, !text[index + 1].isWhitespace { hasOpener = true }
        }
        return false
    }

    /// The text of a line as far as its `$` go: the text, math with its delimiters, and a stand-in for the rest.
    private static func dollarText(of inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let text): return text
            case .math: return "$x$"
            case .strong(let children), .emphasis(let children), .strikethrough(let children), .highlight(let children),
                .underline(let children), .textColor(_, let children), .backgroundColor(_, let children):
                return dollarText(of: children)
            case .link(_, let label): return dollarText(of: label)
            case .lineBreak: return " "
            default: return "x"
            }
        }.joined()
    }

    // MARK: Lists

    private static func renderList(_ items: [MarkdownListItem], marker: (Int) -> String) -> String? {
        var lines: [String] = []
        var number = 0
        for item in items {
            let rendered: [(block: MarkdownBlock, text: String)] = item.blocks.compactMap { block in
                render(block).map { (block, $0) }
            }
            // An item without text keeps its place: its marker alone.
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
            // An item whose first block is a list has no text of its own: its marker goes on a line of its own, else
            // `- - x` would make the nested list's first item the item's text and its other items the item's siblings.
            let startsWithList: Bool
            switch rendered.first?.block {
            case .bulletList?, .numberedList?: startsWithList = true
            default: startsWithList = false
            }
            if startsWithList {
                lines.append(itemMarker)
                for line in itemLines { lines.append(line.isEmpty ? "" : indent + line) }
                continue
            }
            // An item without text holds a no-break space: a bare `-` cannot start a list under a line of text, where
            // Markdown reads it as that line's underline (a heading) or as text.
            let isEmpty = rendered.isEmpty && item.checkbox == nil
            let first = isEmpty ? itemMarker + " \u{00A0}" : itemLines[0].isEmpty ? itemMarker : itemMarker + " " + itemLines[0]
            lines.append(first)
            for line in itemLines.dropFirst() {
                lines.append(line.isEmpty ? "" : indent + line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Tables

    private static func renderTable(header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> String? {
        let columnCount = max(header.count, rows.map({ $0.count }).max() ?? 0)
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
        /// Whether `$` is escaped: only on a line where two could pair into math (`dollarsCouldPair`).
        var escapesDollars = true
        /// Whether the text is a Markdown link's label, where its own brackets are escaped.
        var isInLinkLabel = false
    }

    /// `inlines` written one after the other, `preceding` and `following` the characters outside them.
    private static func renderInlines(_ inlines: [MarkdownInline], context: InlineContext, precededBy preceding: Character? = nil,
                                      followedBy following: Character? = nil) -> String {
        var result = ""
        for (index, inline) in inlines.enumerated() {
            let next: Character? = index + 1 < inlines.count ? firstCharacter(of: inlines[index + 1]) : following
            result += renderInline(inline, context: context, followedBy: next, precededBy: result.last ?? preceding)
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
            return wrap(children, delimiter: "**", context: context, precededBy: preceding, followedBy: following)
        case .emphasis(let children):
            return wrap(children, delimiter: "_", context: context, precededBy: preceding, followedBy: following)
        case .strikethrough(let children):
            return wrap(children, delimiter: "~~", context: context, precededBy: preceding, followedBy: following)
        case .highlight(let children):
            return wrap(children, delimiter: "==", context: context, precededBy: preceding, followedBy: following)
        case .underline(let children):
            return wrapInTags(children, opening: "<u>", closing: "</u>", context: context)
        case .textColor(let color, let children):
            return wrapInTags(children, opening: "<span style=\"color:" + color + "\">", closing: "</span>", context: context)
        case .backgroundColor(let color, let children):
            return wrapInTags(children, opening: "<mark style=\"background:" + color + "\">", closing: "</mark>", context: context)
        case .code(let code):
            let flat = code.replacingEvery("\n", with: " ")
            guard !flat.isEmpty else { return "" }
            let fence = String(repeating: "`", count: longestRun(of: "`", in: flat) + 1)
            let padding = flat.hasPrefix("`") || flat.hasSuffix("`") ? " " : ""
            let escaped = context.isInTableCell ? flat.replacingEvery("|", with: "\\|") : flat
            return fence + padding + escaped + padding + fence
        case .math(let tex):
            let cleaned = cleanedTeX(tex, isInline: true)
            guard !cleaned.isEmpty else { return "" }
            return "$" + (context.isInTableCell ? cleaned.replacingEvery("|", with: "\\|") : cleaned) + "$"
        case .link(let destination, let label):
            return renderLink(destination: destination, label: label, context: context, precededBy: preceding, followedBy: following)
        case .wikiLink(let target, let label, let isEmbed):
            var text = isEmbed ? "![[" : "[["
            text += target
            if let label, !label.isEmpty, label != target {
                let cleanedLabel = label.replacingEvery("[", with: "").replacingEvery("]", with: "")
                    .replacingEvery("|", with: "")
                text += (context.isInTableCell ? "\\|" : "|") + cleanedLabel
            }
            return text + "]]"
        case .image(let source, let alternativeText):
            let alternative = alternativeText.replacingEvery("[", with: "").replacingEvery("]", with: "")
            return "![" + alternative + "](" + linkDestination(source) + ")"
        case .lineBreak:
            return context.lineBreak
        case .markdown(let markdown):
            return markdown
        }
    }

    /// A link: the spaces at the edges of its label written outside the brackets, so that the words beside it stay
    /// apart, and its label's own brackets escaped. A label of spaces alone, or one that is the web address itself,
    /// writes the address. A link to nothing is its label's text.
    private static func renderLink(destination: String, label: [MarkdownInline], context: InlineContext,
                                   precededBy preceding: Character?, followedBy following: Character?) -> String {
        let normalized = MarkdownInlineNormalizer.normalize(label)
        guard !destination.isEmpty else {
            return renderInlines(normalized, context: context, precededBy: preceding, followedBy: following)
        }
        var labelContext = context
        labelContext.isInLinkLabel = true
        let rendered = renderInlines(normalized, context: labelContext)
        var leading = String(rendered.prefix(while: { $0 == " " }))
        let core = trimmed(rendered)
        var trailing = core.isEmpty ? "" : String(rendered.reversed().prefix(while: { $0 == " " }))
        if preceding.map({ $0.isWhitespace }) ?? true { leading = "" }
        if following.map({ $0.isWhitespace }) ?? true { trailing = "" }
        let plainLabel = MarkdownInlineNormalizer.plainText(of: label).trimmingSpaces()
        let isWebAddress = destination.hasPrefix("http://") || destination.hasPrefix("https://")
        if core.isEmpty || (isWebAddress && plainLabel == destination) {
            if core.isEmpty, trailing.isEmpty, let following, following.isLetter || following.isNumber { trailing = " " }
            let before = leading.last ?? preceding
            let after = trailing.first ?? following
            return leading + address(destination, isWebAddress: isWebAddress, precededBy: before, followedBy: after) + trailing
        }
        return leading + "[" + core + "](" + linkDestination(destination) + ")" + trailing
    }

    /// An address shown as itself: bare, as Obsidian writes it, where an autolink reads it whole (after a space or a
    /// line's start, before one or a line's end, not ending in punctuation an autolink leaves out), else between `<`
    /// and `>`, which every reader reads whole. An address that cannot go between them is a link with itself as text.
    private static func address(_ destination: String, isWebAddress: Bool, precededBy preceding: Character?,
                                followedBy following: Character?) -> String {
        if destination.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) {
            return "[" + escapeText(destination, context: InlineContext(lineBreak: " ", isInLinkLabel: true), followedBy: nil, precededBy: nil)
                + "](" + linkDestination(destination) + ")"
        }
        guard isWebAddress, let last = destination.last else { return "<" + destination + ">" }
        let opensCleanly = preceding.map { $0.isWhitespace || $0 == "(" || $0 == "*" || $0 == "_" || $0 == "~" } ?? true
        let closesCleanly = following.map { $0.isWhitespace } ?? true
        let opening = destination.filter { $0 == "(" }.count, closing = destination.filter { $0 == ")" }.count
        let endsCleanly = !"?!.,:;*_~'\"".contains(last) && (last != ")" || opening >= closing)
        return opensCleanly && closesCleanly && endsCleanly ? destination : "<" + destination + ">"
    }

    /// A style's text between its delimiters, written so that Markdown reads them as its start and end (CommonMark's
    /// flanking rules, which Obsidian follows): spaces at its edges, no-break and zero-width ones too, go outside it,
    /// and so does punctuation at an edge where the character outside is neither a space nor punctuation (`did it*.*`
    /// would show its asterisks). A style holding only punctuation and spaces is written as its text, and one that
    /// cannot be opened or closed in place (a link right after a letter, inside bold) as its content without the style.
    /// Emphasis is written with `_`, as Obsidian writes it, unless a letter or digit touches it, where only `*` works.
    private static func wrap(_ children: [MarkdownInline], delimiter: String, context: InlineContext,
                             precededBy preceding: Character?, followedBy following: Character?) -> String {
        var core = children
        var leading = ""
        var trailing = ""
        func takeFront(while shouldTake: (Character) -> Bool) {
            while case .text(let text)? = core.first {
                let taken = String(text.prefix(while: shouldTake))
                leading += taken
                guard taken.count == text.count else {
                    core[0] = .text(String(text.dropFirst(taken.count)))
                    return
                }
                core.removeFirst()
            }
        }
        func takeBack(while shouldTake: (Character) -> Bool) {
            while case .text(let text)? = core.last {
                let taken = String(String(text.reversed()).prefix(while: shouldTake).reversed())
                trailing = taken + trailing
                guard taken.count == text.count else {
                    core[core.count - 1] = .text(String(text.dropLast(taken.count)))
                    return
                }
                core.removeLast()
            }
        }
        func opens() -> Bool {
            guard let first = core.first.flatMap(firstCharacter) else { return false }
            return !isEdgeSpace(first) && (!isPunctuation(first) || isOutsideOfWord(leading.last ?? preceding))
        }
        func closes() -> Bool {
            guard let last = core.last.flatMap(lastCharacter) else { return false }
            return !isEdgeSpace(last) && (!isPunctuation(last) || isOutsideOfWord(trailing.first ?? following))
        }
        takeFront(while: isEdgeSpace)
        takeBack(while: isEdgeSpace)
        if core.isEmpty || core.allSatisfy({ inline in
            if case .text(let text) = inline { return text.allSatisfy { isPunctuation($0) || isEdgeSpace($0) } }
            return false
        }) {
            return escapeText(MarkdownInlineNormalizer.plainText(of: children), context: context, followedBy: following,
                              precededBy: preceding)
        }
        while !opens(), case .text(let text)? = core.first, let first = text.first, isPunctuation(first) {
            takeFront(while: isPunctuation)
            takeFront(while: isEdgeSpace)
        }
        while !core.isEmpty, !closes(), case .text(let text)? = core.last, let last = text.last, isPunctuation(last) {
            takeBack(while: isPunctuation)
            takeBack(while: isEdgeSpace)
        }
        guard !core.isEmpty, opens(), closes() else {
            return renderInlines(children, context: context, precededBy: preceding, followedBy: following)
        }
        var opening = delimiter
        if delimiter == "_", !(isOutsideOfWord(leading.last ?? preceding) && isOutsideOfWord(trailing.first ?? following)) {
            opening = "*"
        }
        // Spaces next to a space outside would show twice.
        if preceding.map({ $0.isWhitespace }) ?? true {
            leading = String(leading.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{200B}" }))
        }
        if following.map({ $0.isWhitespace }) ?? true {
            trailing = String(String(String(trailing.reversed()).drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{200B}" })).reversed())
        }
        let before = escapeText(leading, context: context, followedBy: opening.first, precededBy: preceding)
        let after = escapeText(trailing, context: context, followedBy: following, precededBy: opening.last)
        return before + opening + renderInlines(core, context: context) + opening + after
    }

    private static func wrapInTags(_ children: [MarkdownInline], opening: String, closing: String, context: InlineContext) -> String {
        let inner = renderInlines(children, context: context)
        let leading = inner.prefix(while: { $0 == " " })
        let trailing = inner.reversed().prefix(while: { $0 == " " })
        guard leading.count < inner.count else { return inner }
        let core = inner.dropFirst(leading.count).dropLast(trailing.count)
        return String(leading) + opening + core + closing + String(trailing)
    }

    private static func lastCharacter(of inline: MarkdownInline) -> Character? {
        switch inline {
        case .text(let text): return text.last
        case .lineBreak: return " "
        default: return "*"
        }
    }

    /// A space as a style's edge sees it: Unicode's spaces, the no-break space among them, and the zero-width ones.
    private static func isEdgeSpace(_ character: Character) -> Bool {
        character.isWhitespace || character == "\u{200B}" || character == "\u{FEFF}"
    }

    /// Punctuation as CommonMark's flanking rules see it: ASCII punctuation and Unicode's punctuation and symbols.
    private static func isPunctuation(_ character: Character) -> Bool {
        character.isASCII ? asciiPunctuation.contains(character) : character.isPunctuation || character.isSymbol
    }

    /// Whether a delimiter with `character` beside it, outside the style, is not inside a word: a line's edge, a space
    /// or punctuation (Unicode's punctuation only, which every reading of the rules counts).
    private static func isOutsideOfWord(_ character: Character?) -> Bool {
        guard let character else { return true }
        if character.isWhitespace { return true }
        return character.isASCII ? asciiPunctuation.contains(character) : character.isPunctuation
    }

    private static func linkDestination(_ destination: String) -> String {
        if destination.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" }) {
            return "<" + destination.replacingEvery("<", with: "%3C").replacingEvery(">", with: "%3E") + ">"
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
            case "*", "`":
                result += "\\" + String(character)
            case "$":
                result += context.escapesDollars ? "\\$" : "$"
            case "_":
                let isWordInside = (previous.map { $0.isLetter || $0.isNumber } ?? false)
                    && (next.map { $0.isLetter || $0.isNumber } ?? false)
                result += isWordInside ? "_" : "\\_"
            case "~", "=", "%":
                result += next == character ? "\\" + String(character) : String(character)
            case "[":
                result += context.isInLinkLabel || next == "[" ? "\\[" : "["
            case "]":
                result += context.isInLinkLabel || next == "(" || next == "]" ? "\\]" : "]"
            case "<":
                let opensTag = next.map { $0.isASCII && ($0.isLetter || $0 == "/" || $0 == "!" || $0 == "?") } ?? false
                result += opensTag ? "\\<" : "<"
            case "#":
                // A tag starts after a space or a line's start, not inside a word or an address (`page#part`).
                let isInsideWord = previous.map { $0.isLetter || $0.isNumber || "/.:=&?#_-".contains($0) } ?? false
                result += !isInsideWord && startsTag(characters, after: index, following: following) ? "\\#" : "#"
            case "|":
                result += context.isInTableCell ? "\\|" : "|"
            case "&":
                result += startsEntity(characters, after: index) ? "\\&" : "&"
            default:
                result.append(character)
            }
        }
        return result
    }

    /// Whether the `&` at `index` starts what Markdown reads as an HTML entity: `&nbsp;`, `&#233;`, `&#xE9;`.
    private static func startsEntity(_ characters: [Character], after index: Int) -> Bool {
        var position = index + 1
        if position < characters.count, characters[position] == "#" { position += 1 }
        let start = position
        while position < characters.count, characters[position].isASCII, characters[position].isLetter || characters[position].isNumber {
            position += 1
        }
        return position > start && position < characters.count && characters[position] == ";"
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
        }.filter { !$0.trimmingSpaces().isEmpty }
        return lines.joined(separator: isInline ? " " : "\n")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingSpaces()
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
/// other merge, a style holding a line break is split around it, the spaces at a style's edges move out of it (through
/// the styles inside it too), and texts next to each other join. Runs of spaces become one, as they show in HTML.
public enum MarkdownInlineNormalizer {
    /// `inlines` put in the shape Markdown can write.
    public static func normalize(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        mergeTexts(merge(hoistingEdgeSpaces(inlines.flatMap { normalize($0, insideStyles: []) })))
    }

    /// `inlines` with the spaces at the edges of each style moved out of it, those of the styles at its edges first,
    /// so that no delimiter stands next to a space inside its style. A style left empty goes.
    private static func hoistingEdgeSpaces(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for inline in inlines {
            if let (style, children) = style(of: inline) {
                var inner = mergeTexts(hoistingEdgeSpaces(children))
                var leading = ""
                var trailing = ""
                if case .text(let text)? = inner.first {
                    let spaces = String(text.prefix(while: isEdgeSpace))
                    leading = spaces
                    if spaces.count == text.count { inner.removeFirst() } else { inner[0] = .text(String(text.dropFirst(spaces.count))) }
                }
                if case .text(let text)? = inner.last {
                    let spaces = String(String(String(text.reversed()).prefix(while: isEdgeSpace)).reversed())
                    trailing = spaces
                    if spaces.count == text.count {
                        inner.removeLast()
                    } else {
                        inner[inner.count - 1] = .text(String(text.dropLast(spaces.count)))
                    }
                }
                if !leading.isEmpty { result.append(.text(leading)) }
                if !inner.isEmpty { result.append(make(style, inner)) }
                if !trailing.isEmpty { result.append(.text(trailing)) }
            } else if case .link(let destination, let label) = inline {
                result.append(.link(destination: destination, label: mergeTexts(hoistingEdgeSpaces(label))))
            } else {
                result.append(inline)
            }
        }
        return result
    }

    /// A space a style's delimiter must not stand next to: Unicode's spaces and the zero-width ones.
    private static func isEdgeSpace(_ character: Character) -> Bool {
        (character.isWhitespace && !character.isNewline) || character == "\u{200B}" || character == "\u{FEFF}"
    }

    private enum Style: Hashable {
        case strong, emphasis, strikethrough, highlight, underline
        case textColor(String)
        case backgroundColor(String)
    }

    private static func style(of inline: MarkdownInline) -> (Style, [MarkdownInline])? {
        switch inline {
        case .strong(let children): return (.strong, children)
        case .emphasis(let children): return (.emphasis, children)
        case .strikethrough(let children): return (.strikethrough, children)
        case .highlight(let children): return (.highlight, children)
        case .underline(let children): return (.underline, children)
        case .textColor(let color, let children): return (.textColor(color), children)
        case .backgroundColor(let color, let children): return (.backgroundColor(color), children)
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
        case .textColor(let color): return .textColor(color, children)
        case .backgroundColor(let color): return .backgroundColor(color, children)
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
            case .text(let text): return text.allSatisfy({ $0.isWhitespace })
            case .lineBreak: return true
            case .strong(let children), .emphasis(let children), .strikethrough(let children), .highlight(let children),
                .underline(let children), .textColor(_, let children), .backgroundColor(_, let children):
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
                .highlight(let children), .underline(let children), .textColor(_, let children), .backgroundColor(_, let children):
                return plainText(of: children)
            case .link(_, let label): return plainText(of: label)
            case .wikiLink(let target, let label, _): return label ?? target
            case .image(_, let alternativeText): return alternativeText
            case .lineBreak: return " "
            }
        }.joined()
    }
}
