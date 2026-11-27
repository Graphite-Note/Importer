<!--
File: Differences.md
--------------------
Layer: Tests
Description: Every difference between what this importer writes for Obsidian Importer's API fixtures and the files
             Obsidian Importer expects for them, with the reason for each.

Authors: Bahey Shalash
Version: 0.2
Date: 27/11/2026
-->

# Differences from Obsidian Importer's API output

`NotionAPITests` compares its output for each fixture with `expected-importer/`. Against upstream's `expected/`, the differences are below. "Reads the same" means Obsidian shows the two the same way. Every file here ends with a line end, as text files do, where upstream's do not.

## example-page.md

| Difference | Why |
| --- | --- |
| `_italic_` instead of `*italic*` | Reads the same. The writer uses `_` unless the mark touches a letter or digit, as the HTML import does. |
| An empty line between the bulleted list, the numbered list and the to-dos | Without it Markdown joins adjacent lists of different kinds into one. |
| `> [!tip] 💡 Something to note.` on one line | The callout's own text is its title, as the HTML import writes callouts. Its children follow as its body. |
| `> [!note]- More detail` instead of `+` | A toggle is closed until opened in Notion, so its callout is folded, as in the HTML import. |
| The bookmark as `https://example.com/reading` | Reads the same: a link whose text is its address is written as the address. |
| `A date mention: 2024-06-01` without the spaces around the date | Reads the same. |
| A table of contents listing the page's headings | The page has a table of contents block. Upstream leaves it out. Here it lists the headings as links, as the HTML export's own table of contents does. |
| The indented lines are paragraphs of their own, and the report says the indent was dropped | Four spaces after a paragraph continue that paragraph in Markdown, so upstream's indented lines read as part of the line above. |

## toggle-headings-page.md and meeting-notes-page.md

Only the line end at the end of the file.

## example-database.md

The same properties, written between `---` lines as front matter. The test prints each note's title before its front matter, as upstream's expected file does.

## board-views.base

| Difference | Why |
| --- | --- |
| `filters: file.folder == "Notion/Tasks"` | A base shows the notes of its rows' folder, as the HTML import's bases do. Upstream adds a `base` property to each row and filters on it. |
| No `displayName` for properties shown under their own name | Reads the same: Bases shows a property's name when it has no display name. |
| `name: All tasks` instead of `Table View` | The table view keeps the name Notion gives it. |
| `tags` instead of `Tags` | A multi-select called Tags becomes the notes' `tags`, so its values are tags, as in the HTML import. |
| `- ""` instead of `- ` in `groupOrder` | Reads the same: both are the column of notes without a value. |
| `image: note.banner` instead of `note.cover` for the gallery showing page covers | A page's cover is written as its `banner` property (see "Page covers" below), so the cards show it from there. |

## Page covers

Upstream writes a page's cover as a `cover` property. This importer writes it as `banner`, on purpose: `banner` is the property Graphite draws a note's cover from, and the one the Banners and Pixel Banner plugins read in Obsidian, so the cover shows in both. A cover from the web is written as its address. A cover uploaded to Notion is downloaded beside the note, as its other files are, and written as a link to it (`banner: "[[Notion/Course/cover.png]]"`). Upstream writes only a cover from the web. None of upstream's fixtures has a cover, so no expected file shows the difference. `NotionCoverTests` checks it.
