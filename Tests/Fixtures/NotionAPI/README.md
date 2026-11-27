<!--
File: README.md
---------------
Layer: Tests
Description: Where the test material of Notion's API comes from, its license, and what each file tests.

Authors: Bahey Shalash
Version: 0.1
Date: 27/11/2026
-->

# Notion API test material

From [Obsidian Importer](https://github.com/obsidianmd/obsidian-importer), commit `fa9444a188459f227b07ec121ad03d26bd6b301a` (2026-11-12), folder `tests/notion-api`, fetched unchanged. Each file is hand-written by upstream to the shape of Notion's API answers (Notion-Version 2025-09-03): no real workspace, made-up identifiers and content. MIT licensed, notice below.

| File | What it tests here |
| --- | --- |
| `example-page.json`, `expected/example-page.md` | Every block type the converter handles, read by `NotionAPIPageReader`. |
| `toggle-headings-page.json`, `expected/toggle-headings-page.md` | Toggle headings and their content. |
| `meeting-notes-page.json`, `expected/meeting-notes-page.md` | AI meeting notes (`transcription` and `meeting_notes`) and their sections. |
| `example-database.json`, `expected/example-database.md` | A data source's rows: numbers, people, a relation inside the import and one leaving it. |
| `board-views.json`, `expected/board-views.base` | A data source with a formula and its table and board views, as `GET /v1/views` gives them. |
| `example-search.json`, `reimport-workspace.json`, `synced-workspace.json`, `expected/example-search.txt` | Kept for the search picker and importing again, not yet read by a test. |

`FakeNotionWorkspace` (`Tests/NotionImportTests/NotionAPITestSupport.swift`) serves the page, toggle, meeting and board fixtures as one workspace for whole imports. Made here, not upstream: `expected-importer/`, the output of this importer for the fixtures, written again with `IMPORTER_RECORD_EXPECTED=1 swift test`. [Differences.md](Differences.md) explains each difference from upstream's expected files.

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
