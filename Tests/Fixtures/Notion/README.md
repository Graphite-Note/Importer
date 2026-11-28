<!--
File: README.md
---------------
Layer: Tests
Description: Where the Notion test material comes from, its license, and what each file tests.

Authors: Bahey Shalash
Version: 0.2
Date: 28/11/2026
-->

# Notion test material

## Made for this repository

`signals-and-systems.zip`: a course workspace of fictional content, "Signals & Systems", made in Notion on 2026-11-28 for the README's pictures and exported as HTML in Notion's format since 2025 (14 files, 82 KB). It holds a cover and an icon, a callout, three columns of links to pages with their icons, colored headings, a highlight, colored bold, toggle headings, equations, a checklist, code, the database Assignments and a linked view of it filtered to two rows, and rows whose titles hold a colon. Part of this repository, under its license, and free to show. Imported by `NotionReadmeDemoTests`.

## From Obsidian Importer

From [Obsidian Importer](https://github.com/obsidianmd/obsidian-importer), commit `fa9444a188459f227b07ec121ad03d26bd6b301a` (2026-11-12), folder `tests/notion`, fetched unchanged. MIT licensed, notice below.

| File | Upstream path | What it tests here |
| --- | --- | --- |
| `notion-testspace.zip` | `tests/notion/notion-testspace.zip` | Notion's HTML export: a zip holding a deflated `Part-1` zip, four pages, five attachments with odd names. Imported by `NotionFixtureImportTests`. |
| `expected/notion-testspace/*.md` | `tests/notion/expected/notion-testspace/` | The notes upstream's conversion gives for it. Each note written here is compared with them line by line, and every difference is listed in `expected-importer/upstream-differences/` and explained in [Differences.md](Differences.md). |
| `database-row.html`, `expected/database-row.md` | `tests/notion/database-row.html`, `tests/notion/expected/database-row.md` | A database row page with its properties. Read here to the same front matter. |
| `Notion.Test.Export.zip` | `tests/notion/Notion.Test.Export.zip` | Notion's Markdown & CSV export, which is refused with its reason. |

Made here, not upstream: `expected-importer/notion-testspace/` (the vault this importer writes for `notion-testspace.zip`, attachments left out as they are the export's own bytes) and `expected-importer/upstream-differences/`. Both are written again with `IMPORTER_RECORD_EXPECTED=1 swift test`, after a change of output checked by hand.

## License of the upstream files

Copyright (c) 2023 Obsidian

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
