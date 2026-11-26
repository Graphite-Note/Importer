/**
 * File: MarkdownDocument.swift
 * ----------------------------
 * Layer: Core
 * Description: The model every format reads its pages into: blocks (paragraphs, headings, lists, quotes, callouts,
 *              code, math, tables) holding inline text (styles, links, wiki links, math), written to Markdown by
 *              MarkdownWriter.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

/// A run of inline content.
public indirect enum MarkdownInline: Equatable, Sendable {
    /// Plain text, escaped when written so that it reads as written.
    case text(String)
    /// Bold text.
    case strong([MarkdownInline])
    /// Italic text.
    case emphasis([MarkdownInline])
    /// Struck-out text.
    case strikethrough([MarkdownInline])
    /// Highlighted text (`==…==`).
    case highlight([MarkdownInline])
    /// Underlined text, which Markdown has no syntax for (`<u>…</u>`).
    case underline([MarkdownInline])
    /// Inline code.
    case code(String)
    /// Inline math in TeX (`$…$`).
    case math(String)
    /// A link to a URL.
    case link(destination: String, label: [MarkdownInline])
    /// A wiki link to a note, attachment or heading of the vault, with the text shown instead of the target, and
    /// whether it embeds the target (`![[…]]`).
    case wikiLink(target: String, label: String?, isEmbed: Bool)
    /// An image from a URL.
    case image(source: String, alternativeText: String)
    /// A line break inside a paragraph.
    case lineBreak
    /// Text written as it is, already Markdown.
    case markdown(String)
}

/// How a callout folds.
public enum MarkdownCalloutFolding: Equatable, Sendable {
    /// Always open, no fold control (`> [!note]`).
    case notFoldable
    /// Folded until opened (`> [!note]-`).
    case folded
    /// Open, and foldable (`> [!note]+`).
    case unfolded
}

/// One item of a list.
public struct MarkdownListItem: Equatable, Sendable {
    /// The item's check box: `nil` for none, `false` unchecked, `true` checked.
    public var checkbox: Bool?
    /// The item's content: its first block is written on the item's line.
    public var blocks: [MarkdownBlock]

    public init(checkbox: Bool? = nil, blocks: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

/// A block of a note.
public indirect enum MarkdownBlock: Equatable, Sendable {
    /// A paragraph.
    case paragraph([MarkdownInline])
    /// A heading of level 1 to 6.
    case heading(level: Int, [MarkdownInline])
    /// A bulleted list, its items with or without check boxes.
    case bulletList([MarkdownListItem])
    /// A numbered list starting at `start`.
    case numberedList(start: Int, [MarkdownListItem])
    /// A quote.
    case quote([MarkdownBlock])
    /// An Obsidian callout: its type (`note`, `tip`, …), its title, its folding and its body.
    case callout(type: String, title: [MarkdownInline], folding: MarkdownCalloutFolding, body: [MarkdownBlock])
    /// A fenced code block in `language` (empty for none).
    case codeBlock(language: String, code: String)
    /// A block of math in TeX (`$$…$$`).
    case mathBlock(String)
    /// A horizontal rule.
    case thematicBreak
    /// A table: its header row and its rows, each a list of cells.
    case table(header: [[MarkdownInline]], rows: [[[MarkdownInline]]])
}
