<!--
File: Differences.md
--------------------
Layer: Tests
Description: Every difference between the notes this importer writes for Obsidian Importer's Notion test export and
             the notes Obsidian Importer expects for it, with the reason for each.

Authors: Bahey Shalash
Version: 0.6
Date: 28/11/2026
-->

# Differences from Obsidian Importer's notes

`NotionFixtureImportTests` imports `notion-testspace.zip` and compares each note with upstream's note in `expected/notion-testspace/`. The lines that differ are recorded in `expected-importer/upstream-differences/<note>.diff` (`@@ n` gives the line of upstream's note, `-` its lines, `+` the lines written here), and the test fails when they change. Each kind of difference is below. "Reads the same" means Obsidian shows the two the same way.

## Notion-Testspace and Attachment Tests

The end of the file: notes written here end with a line end, as text files do. Upstream's end without one. In Notion-Testspace, line 5: the links to the two subpages are the lines of one block (`[[Block Reference]]  ` then `[[Formatting Tests]]`), as Notion draws links to pages one after the other in a compact list, where upstream writes a paragraph each.

## Block Reference

| Lines (upstream) | Difference | Why |
| --- | --- | --- |
| 9 to 10 | The table of contents nests "A Heading 2 Block" under its heading 1 and "A Heading 3 Block" under that. | Notion marks each entry's level (`table_of_contents-indent-N`). Upstream's own code nests them too, but its test DOM leaves them flat (noted in Graphite's `Docs/Notion-import-todo.md`, section 3). |
| 39 | The toggle is a folded callout, `> [!note]- This is a toggle-list item…`, its content inside. | A toggle hides its content until opened: a folded callout does the same in Obsidian and Graphite. Upstream writes a list item with its content always shown. |
| 54 | ` ```python ` instead of ` ```Python `. | Code languages are written as the highlighter names them, in lowercase (`C++` becomes `cpp`, `Plain Text` none). |
| 59 | `$$` on lines of their own, the TeX as Notion wrote it, without two spaces at each line end. | Reads the same. Upstream's spaces are hard line breaks left inside the math by its HTML conversion. |
| 68, 72, 76, 80, 84 | Callout types from the icon: `[!tip] 💡` for the light bulb emoji, `[!info]` for Notion's "info" icon, `[!note]` without an icon. The title line holds the icon alone, and the callout's text is its body, from its first line. | A Notion callout has no title: Notion draws its icon and its text as plain body text in a box, which a callout whose title is its icon shows. Upstream writes every callout `[!important]` and drops its icon. The empty line reads the same either way. The empty callout's title is empty, where upstream leaves two spaces. |
| 88 | The bookmark is a link with the page's title, followed by the first sentence of its description, instead of an `[!info]` callout. | A bookmark is a link: written as one, it stays a link in Obsidian, Graphite and any Markdown reader. |
| 98 | The external image is `![](…)` alone, not wrapped in a link to itself. | Reads the same: Obsidian opens an image on click either way. |
| 101 | Line end at the end of the file. | As above. |

## Formatting Tests

| Lines (upstream) | Difference | Why |
| --- | --- | --- |
| 18, 22, 25, 39, 43, 49, 53, 65, 74 and others | No hard line break (two spaces) at the end of a paragraph or list item. Two line breaks in a row start a new paragraph (an empty line) instead of `  ` lines. | Reads the same. A hard break at the end of a paragraph does nothing, and a line holding only spaces is an empty line in Markdown, which upstream's page itself asks for ("2 forced linebreaks → 1 new Obsidian paragraph"). |
| Empty lines in quotes and callouts (56, 62, 98, 107 to 132, 146 and others) | `>` instead of `> `. | Reads the same, without trailing spaces. |
| 70, 79, 83, 135, 138, 142, 236, 244 | `[!info]` instead of `[!important]`, the title line empty (the icon is Notion's own picture) and the text in the body, its first line included. | These callouts carry Notion's "info" icon, and a Notion callout has no title. As in Block Reference. |
| 100, 115, 148, 163, 220, 239, 247, 259, 267, 297, 307 | Math blocks with `$$` on their own lines, the TeX as Notion wrote it (`x  : &` keeps its two spaces). | Reads the same, as in Block Reference. Upstream collapses spaces inside the TeX as if it were text. |
| 163, 220 | Inside a list item, the empty lines between blocks are empty, not four spaces. | Reads the same. |
| 188, 190, 199 | `\#\_`, `\#\_123`, `\#§±\_-123`: the `_` is escaped too. | Reads the same. A `_` at the edge of a word can start or end italics, so it is escaped wherever it could. Inside a word (`snake_case`) it is not. |
| 210, 214 | ` ``` ` and `#abc` inside the code block, instead of ` ```Plain ` and `\#abc`. | Notion's "Plain Text" has no highlighting, so no language is written. Upstream escapes the `#` inside a code block, where the backslash then shows, which its own page says must not happen. |
| 220, 228 | The empty paragraph Notion leaves before "Mathematical Equations" is not written. The line comparison counts the math block and the list item after it as moved past that paragraph's lines, so they show as removed at 220 and added at 228. | Reads the same. |
| 287 | ` ```latex ` instead of ` ```LaTeX `. | Lowercase language, as in Block Reference. |
| 77 | `_**double linebreak**_` instead of `_**double**_ _**linebreak**_`. | Two runs of one style with a space between are one run, which reads the same. |
| 87, 89 | The heading and the paragraph in Notion's pink text inside their highlight are `==~={#d15796}…=~==`, the paragraph's yellow background the same highlight. | Notion's text colors are kept in the Colors plugin's syntax, which Graphite reads and writes and Obsidian draws with that plugin, inside the highlight so that the markers stay apart. Upstream drops the colors and keeps the highlight. |
| 327 | `[[Formatting Tests#Quotes, Callouts + Nesting]]` instead of `[[Formatting Tests]]`. | Notion's export leaves the heading out of the link itself but writes it in the link's text, a Notion address ending in the heading's block identifier. That identifier is a heading of the page, so the link goes to the heading. The next link points at a text block, which Obsidian cannot link to without a block identifier in the note, so it stays a link to the page. |
| 340 | Line end at the end of the file. | As above. |

## Upstream's database row

`database-row.html` gives upstream's `expected/database-row.md` byte for byte, but for the line end at the end of the file and two numbers.

| Difference | Why |
| --- | --- |
| `Price (USD): 1234.56` instead of `$1,234.56`, `Discount: 0.15` instead of `15%` | A number property is a number, so that Bases can sort and compute with it: the amount without its currency and separators, a percent as the fraction Notion keeps (0.15 for 15 %). The format is reported. `R$67.3` stays text: its currency is written with a letter. |

## Page covers

Upstream writes a page's cover as a `cover` property. This importer writes it as `banner`, on purpose: `banner` is the property Graphite draws a note's cover from, and the one the Banners and Pixel Banner plugins read in Obsidian, so the cover shows in both. A cover held in the export is written as a link to the copied picture (`banner: "[[cover.png]]"`), a cover from the web as its address. `notion-testspace.zip` has no cover, so no expected note shows the difference. `NotionCoverTests` checks it.
