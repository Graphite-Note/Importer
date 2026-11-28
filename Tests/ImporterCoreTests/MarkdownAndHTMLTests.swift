/**
 * File: MarkdownAndHTMLTests.swift
 * --------------------------------
 * Layer: Tests
 * Description: The Markdown writer (escaping, styles, lists, callouts, math, code, tables), the HTML reader,
 *              front matter and base YAML, and CSV tables.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 28/11/2026
 */

import Foundation
@testable import ImporterCore
import Testing

@Suite("Markdown writer")
struct MarkdownWriterTests {
    private func write(_ blocks: [MarkdownBlock]) -> String {
        MarkdownWriter.markdown(for: blocks)
    }

    @Test("Text that Markdown or Obsidian would read as syntax is escaped")
    func escaping() {
        let text = write([.paragraph([.text("a*b $5 #tag #123 snake_case _x [[no]] <div> ==no== %%no%% ~~no~~ C:\\path")])])
        #expect(text == "a\\*b $5 \\#tag #123 snake_case \\_x \\[[no\\]] \\<div> \\==no\\== \\%%no\\%% \\~~no\\~~ C:\\path\n")
        // `$` is escaped where two could pair into math, and kept as written where they cannot.
        #expect(write([.paragraph([.text("$5 and $x$")])]) == "\\$5 and \\$x\\$\n")
        #expect(write([.paragraph([.text("costs $5 and $10")])]) == "costs $5 and $10\n")
        #expect(write([.paragraph([.text("# not a heading")])]) == "\\# not a heading\n")
        #expect(write([.paragraph([.text("1. not a list")])]) == "1\\. not a list\n")
        #expect(write([.paragraph([.text("- not a list")])]) == "\\- not a list\n")
        #expect(write([.paragraph([.text("> not a quote")])]) == "\\> not a quote\n")
    }

    @Test("Styles drop spaces at their edges, split at line breaks, merge with their neighbours, and nest once")
    func styles() {
        #expect(write([.paragraph([.text("a"), .strong([.text(" b ")]), .text("c")])]) == "a **b** c\n")
        #expect(write([.paragraph([.strong([.text("one"), .lineBreak, .text("two")])])]) == "**one**  \n**two**\n")
        #expect(write([.paragraph([.strong([.text("a")]), .text(" "), .strong([.text("b")])])]) == "**a b**\n")
        #expect(write([.paragraph([.strong([.strong([.text("a")])])])]) == "**a**\n")
        #expect(write([.paragraph([.text("in"), .emphasis([.text("side")]), .text(" and "), .emphasis([.text("apart")])])])
            == "in*side* and _apart_\n")
    }

    @Test("Two line breaks in a row start a new paragraph, line breaks at the ends are dropped")
    func lineBreaks() {
        #expect(write([.paragraph([.lineBreak, .text("a"), .lineBreak, .text("b"), .lineBreak, .lineBreak, .text("c"), .lineBreak])])
            == "a  \nb\n\nc\n")
        #expect(write([.paragraph([.lineBreak])]) == "")
    }

    @Test("Lists nest by four spaces, with check boxes and numbers from their start")
    func lists() {
        let nested = MarkdownBlock.bulletList([MarkdownListItem(blocks: [.paragraph([.text("child")])])])
        let text = write([
            .bulletList([MarkdownListItem(blocks: [.paragraph([.text("one")]), nested]),
                         MarkdownListItem(checkbox: true, blocks: [.paragraph([.text("done")])])]),
            .numberedList(start: 3, [MarkdownListItem(blocks: [.paragraph([.text("three")]), .mathBlock("x")])]),
        ])
        #expect(text == "- one\n    - child\n- [x] done\n\n3. three\n\n    $$\n    x\n    $$\n")
    }

    @Test("Callouts fold, quotes nest, and math, code and tables take their Obsidian forms")
    func blocks() {
        #expect(write([.callout(type: "note", title: [.text("Title")], folding: .folded,
                                body: [.paragraph([.text("a")]), .quote([.paragraph([.text("b")])])])])
            == "> [!note]- Title\n> a\n>\n> > b\n")
        #expect(write([.mathBlock("  \\\\ x = 1 \n\n  y \\\\ \n")]) == "$$\nx = 1\n  y\n$$\n")
        #expect(write([.paragraph([.math(" a\nb ")])]) == "$a b$\n")
        #expect(write([.codeBlock(language: "swift", code: "let a = \"```\"\n")]) == "````swift\nlet a = \"```\"\n````\n")
        #expect(write([.table(header: [[.text("a|b")], [.text("c")]],
                              rows: [[[.wikiLink(target: "Note", label: "Shown", isEmbed: false)]]])])
            == "| a\\|b | c |\n| --- | --- |\n| [[Note\\|Shown]] |  |\n")
    }

    @Test("Links: a bare address for a link to itself, angle brackets around addresses with spaces")
    func links() {
        #expect(write([.paragraph([.link(destination: "https://a.org", label: [.text("https://a.org")])])]) == "https://a.org\n")
        #expect(write([.paragraph([.link(destination: "https://a.org/x y", label: [.text("x")])])]) == "[x](<https://a.org/x y>)\n")
        #expect(write([.paragraph([.wikiLink(target: "a.png", label: nil, isEmbed: true)])]) == "![[a.png]]\n")
    }
}

@Suite("HTML reader")
struct HTMLDocumentTests {
    @Test("Elements nest as their tags say, void and raw-text elements read right, references decode")
    func tree() throws {
        let document = HTMLDocument("<!doctype html><p id=\"x\" class=\"a b\">one &amp; &#x27;two&#39; &nbsp;<br/>three<div class=indented><p>inner</p></div></p><script>if (a < b) {}</script><!-- note --><img src='i.png'>")
        let paragraph = try #require(document.firstElement(where: { $0.tagName == "p" }))
        #expect(paragraph.classes == ["a", "b"])
        #expect(paragraph.attributes["id"] == "x")
        #expect(paragraph.children.first?.text == "one & 'two' \u{A0}")
        #expect(paragraph.firstDescendant(where: { $0.hasClass("indented") })?.textContent == "inner")
        #expect(document.firstElement(where: { $0.tagName == "script" })?.textContent == "if (a < b) {}")
        #expect(document.firstElement(where: { $0.tagName == "img" })?.attributes["src"] == "i.png")
        #expect(document.root.descendants(where: { $0.tagName == "br" }).count == 1)
    }

    @Test("An end tag without its start is ignored, and closes the elements opened inside it")
    func strayEndTags() {
        let document = HTMLDocument("<div><span>a</p>b</div>c")
        #expect(document.root.textContent == "abc")
        #expect(document.firstElement(where: { $0.tagName == "span" })?.textContent == "ab")
    }
}

@Suite("Front matter, bases and CSV")
struct FrontMatterBaseAndCSVTests {
    @Test("Texts are quoted only where YAML would read them otherwise")
    func quoting() {
        var frontMatter = FrontMatter()
        frontMatter.set("plain", to: .text("Double boiler, plumbed in."))
        frontMatter.set("number-like", to: .text("007"))
        frontMatter.set("yes", to: .text("yes"))
        frontMatter.set("colon", to: .text("a: b"))
        frontMatter.set("link", to: .list(["[[Note]]"]))
        frontMatter.set("with: colon", to: .checkbox(true))
        frontMatter.set("date-like", to: .text("2024-03-01"))
        frontMatter.set("line", to: .text("a\nb"))
        #expect(frontMatter.yaml == """
            ---
            plain: Double boiler, plumbed in.
            number-like: "007"
            "yes": "yes"
            colon: "a: b"
            link:
              - "[[Note]]"
            "with: colon": true
            date-like: "2024-03-01"
            line: "a\\nb"
            ---

            """)
    }

    @Test("A base shows the notes of its folder in a table")
    func base() {
        let base = BaseFile(folder: VaultPath(components: ["Notion", "Tasks"])!, displayNames: [("file.name", "Task")],
                            views: [BaseFile.View(type: "table", name: "Table", order: ["file.name", "Due date"])])
        #expect(base.yaml == """
            filters: file.folder == "Notion/Tasks"
            properties:
              file.name:
                displayName: Task
            views:
              - type: table
                name: Table
                order:
                  - file.name
                  - Due date

            """)
    }

    @Test("CSV fields hold commas, quotes and line breaks, a byte order mark is ignored")
    func csv() {
        let table = CSVTable("\u{FEFF}Name,Notes\r\nA,\"one, two\"\r\nB,\"say \"\"hi\"\"\nagain\"\r\n,\n")
        #expect(table.header == ["Name", "Notes"])
        #expect(table.rows == [["A", "one, two"], ["B", "say \"hi\"\nagain"], ["", ""]])
        #expect(table.value("Notes", in: table.rows[0]) == "one, two")
    }
}
