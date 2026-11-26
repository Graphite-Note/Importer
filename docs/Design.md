<!--
File: Design.md
---------------
Layer: Documentation
Description: How the Importer is built: its layers, what the host provides, how it reaches Graphite (linked first,
             a downloadable WebAssembly plugin later), how Notion is read and what it does better than Obsidian's
             Importer.

Authors: Bahey Shalash
Version: 0.1
Date: 26/11/2026
-->

# Design

Decided 2026-11-26: the importers are written in Swift in this repository instead of forking Obsidian's JavaScript Importer. Notion first, the other formats after. Graphite links the package first and later loads it as a downloadable plugin compiled to WebAssembly.

## Aims

1. **Ordinary files.** An import is a folder of Markdown notes, `.base` files and attachments that Obsidian and Graphite read alike. Nothing needs the importer afterwards.
2. **Nothing lost in silence.** Every page and database ends in the import report, a note in the import's folder that says what was converted, what was simplified (a column layout flattened, a synced block copied, a formula function Bases lacks) and what was left out, with a link to each note.
3. **Bounded memory.** An export of several GB is read entry by entry from the picked file, never loaded whole. Attachments are copied in pieces.
4. **Never overwrite.** A destination refuses to replace a file. Importing again updates only notes the importer wrote and nobody edited since.
5. **One code base everywhere.** The core uses only the parts of Foundation that also exist on Linux and on WebAssembly (no Apple frameworks, no `NSString` bridging, no Combine, no Dispatch), so the same code runs in the Mac and iPad apps, in tests on Linux, and as a WebAssembly plugin.

## Layers

| Target | Holds |
| --- | --- |
| `ImporterCore` | Vault file names (`VaultFileName`), the names taken in a folder (`VaultFolderNames`), vault paths (`VaultPath`), the destination (`ImportDestination`). Planned: the reading of zip archives, Markdown and front matter writing, `.base` writing, links between imported notes, the import report, progress and cancellation. |
| `NotionImport` | Notion's export names (`NotionExportEntryName`). Planned: the HTML export, the API, Notion's formulas in Bases' formula language. |

A format reads its source into a small model of pages, blocks, properties and databases, then one writer per output kind turns that model into files. Formats share the writers, so Markdown, links and bases are written the same way whatever the source.

## What the host provides

The importer opens no file and sends no request on its own. The host passes:

- **The source** to read: random access to the picked export (read a range of bytes, the size), so a zip's central directory is read first and each entry is inflated as it is converted.
- **The destination** (`ImportDestination`): make a folder, write a new file, list a folder. Graphite writes through its coordinated vault writes, so iCloud and the index see each file once. `FolderImportDestination` writes a folder on disk, for tests and tools.
- **The transport**, for API imports: send a request, receive the answer. Graphite uses `URLSession` with the token from the Keychain. The WebAssembly build passes requests to the plugin runtime's `requestUrl`.
- **Progress and cancellation**: the importer reports pages done and pages left, and stops at the next page when cancelled, leaving a usable partial import and its report.

## Reaching Graphite

1. **Linked.** Graphite depends on this package with an exact version, as it depends on MermaidDiagrams. Import › From Notion… opens a native sheet. Nothing of the importer is made until that sheet opens, so it costs nothing at launch or at rest.
2. **Downloadable.** Apple's guideline 2.5.2 refuses downloaded native code on iOS, but code run by WebKit is allowed, and Graphite's community-plugin runtime is a WKWebView. The package compiled to WebAssembly with the Swift SDK for WebAssembly, plus a small JavaScript plugin around it, becomes a plugin installed from Graphite's plugin list. Once it works on the iPad and the Mac, Graphite drops the linked copy and the app shrinks by the importer's size. Open questions for this step: the size of the WebAssembly module with Foundation, and the memory a large export takes in the web view.

## Notion

### From the HTML export

Notion's export is a zip (a zip of `Part-N` zips for large workspaces). Each page is `<title> <identifier>.html`, its subpages in a folder of the same name, each database a `.csv` plus `_all.csv`. Pages become notes, nested pages become folders, links between pages become wiki links resolved by page identifier, attachments are copied next to their notes. Databases are rebuilt as bases from the HTML table of each database page, with property types read from the table's markup. A Markdown export is refused, as it leaves out data.

### From the API

An internal integration's token (`ntn_…`), kept in the Keychain, never in a file or a log. Requests keep to Notion's limit of 3 a second, back off on 429 and 5xx, and resume after a lost network. Attachments are downloaded while their page is converted, as Notion's file links expire after about an hour.

### Better than Obsidian's Importer

| Obsidian Importer 3.2.0 | Here |
| --- | --- |
| HTML export: databases become plain pages | Databases become bases with typed properties |
| API: only table views and boards | Table, gallery, list and board views as Bases table, cards, list and Kanban views, with their filters, sorts and groups where Bases can express them. Calendar, timeline and chart views reported |
| Linked database views skipped | A view of another database becomes a view in that database's base, embedded where the page had it |
| Log shown only in the modal | The import report, a note kept in the vault |
| Callouts, toggles and equations partly kept | Callouts with their icons as Obsidian callouts, toggles and toggle headings as folded callouts, math as `$…$` and `$$…$$`, code blocks with their language |
| JavaScript in a web view on iOS | Native code in the app, then WebAssembly in the plugin runtime |

Each row is a plan until the import of the test workspace shows it.

## Tests

Swift Testing. Each format is tested on recorded material made for the purpose, never on personal notes: a Notion test workspace filled by a script, its HTML export and its API answers recorded with the token and user names removed. Each import is compared file by file with an expected vault kept beside the fixtures, and with the output of Obsidian's Importer on the same material.
