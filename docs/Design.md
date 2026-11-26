<!--
File: Design.md
---------------
Layer: Documentation
Description: How the Importer is built: its layers, what the host provides, how it reaches Graphite (linked first,
             a downloadable WebAssembly plugin later), how Notion is read and what it does better than Obsidian's
             Importer.

Authors: Bahey Shalash
Version: 0.2
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
| `ImporterCore` | Vault file names (`VaultFileName`), the names taken in a folder (`VaultFolderNames`), vault paths (`VaultPath`), the destination (`ImportDestination`, `FolderImportDestination`). The source read by range (`RandomAccessSource`), zip archives with zip64 (`ZipArchive`), a DEFLATE decoder (`Inflater`) and CRC-32, the files of an export across its parts and nested zips (`ExportFileTree`), temporary storage for compressed nested zips (`TemporaryStorage`). An HTML reader (`HTMLDocument`), CSV tables (`CSVTable`). The model of a note (`MarkdownBlock`, `MarkdownInline`) and its writer (`MarkdownWriter`), front matter and property types (`FrontMatter`, `PropertyType`), bases (`BaseFile`), the import report (`ImportReport`). |
| `NotionImport` | Notion's export names (`NotionExportEntryName`), the HTML export (`NotionHTMLImporter`, `NotionVaultPlan`, `NotionPageReader`, `NotionPropertyReader`, `NotionDateParser`). Planned: the API, Notion's formulas in Bases' formula language. |
| `ImporterCommand` | The `importer` command, for manual runs: imports into a folder on disk. |

A format reads its source into a small model of pages, blocks, properties and databases, then one writer per output kind turns that model into files. Formats share the writers, so Markdown, links and bases are written the same way whatever the source.

## What the host provides

The importer opens no file and sends no request on its own. The host passes:

- **The source** to read: random access to the picked export (read a range of bytes, the size), so a zip's central directory is read first and each entry is inflated as it is converted.
- **The destination** (`ImportDestination`): make a folder, write a new file, list a folder. Graphite writes through its coordinated vault writes, so iCloud and the index see each file once. `FolderImportDestination` writes a folder on disk, for tests and tools.
- **The transport**, for API imports: send a request, receive the answer. Graphite uses `URLSession` with the token from the Keychain. The WebAssembly build passes requests to the plugin runtime's `requestUrl`.
- **Temporary storage** (`TemporaryStorage`), for the few bytes that must be read again by range: a `Part-N` zip compressed inside the download is inflated there before its central directory is read. A zip stored inside another is read where it lies.
- **Progress and cancellation**: the importer reports pages done and pages left, and stops at the next page when its task is cancelled, leaving a usable partial import and its report.

## Reaching Graphite

1. **Linked.** Graphite depends on this package with an exact version, as it depends on MermaidDiagrams. Import › From Notion… opens a native sheet. Nothing of the importer is made until that sheet opens, so it costs nothing at launch or at rest.
2. **Downloadable.** Apple's guideline 2.5.2 refuses downloaded native code on iOS, but code run by WebKit is allowed, and Graphite's community-plugin runtime is a WKWebView. The package compiled to WebAssembly with the Swift SDK for WebAssembly, plus a small JavaScript plugin around it, becomes a plugin installed from Graphite's plugin list. Once it works on the iPad and the Mac, Graphite drops the linked copy and the app shrinks by the importer's size. Open questions for this step: the size of the WebAssembly module with Foundation, and the memory a large export takes in the web view.

## Notion

### From the HTML export

Notion's export is a zip (a zip of `Part-N` zips for large workspaces), everything inside a folder `Export-<identifier>` that the import leaves out. Each page is `<title> <identifier>.html`, its subpages in a folder of the same name, each database's rows in the folder of its page, with a `.csv` and an `_all.csv`. Exports whose files were renamed without identifiers are read too: a page is then known by the identifier in its `article` element and linked to by its path.

The import reads every page twice. The first pass keeps each page's whole title (the file name holds a shortened copy), whether it is a database, its headings, and the dates of its properties (to tell day-first from month-first dates). The vault places are then claimed, folder by folder, against the names already in the vault: a page's note and the folder of its subpages share one name (`Week 1.md` and `Week 1/`), a second page of the same title gets `Week 1 2`. Only then is each page converted and written, so every link resolves by page identifier, whatever its file was called. A link names the note alone when no other file of the import has its name, else its vault path.

- Pages become notes, their icon and cover as the `icon` and `cover` properties, their description as the first paragraph.
- Blocks: headings, paragraphs, lists, to-dos, quotes, code with its language in the highlighter's name, equations as `$…$` and `$$…$$`, simple tables, dividers, images and files (embedded when in the export), bookmarks and embeds as links, links to pages as wiki links, the table of contents nested by level. Callouts keep their emoji in the title, their type taken from the icon (`[!tip]` for a light bulb, `[!warning]` for a warning sign, `[!info]` for Notion's info icon, `[!note]` otherwise). Toggles become folded callouts. Toggle headings stay headings: headings fold in Obsidian and Graphite, and the links to them keep working. Columns are flattened, one after the other, and reported. Synced blocks reach the HTML export as ordinary blocks, so they are copied without a mark to report.
- Background colors become highlights, as do text colors other than gray. Notion's line break before a change of style, right after a line break, is dropped.
- A database's page becomes a base: a table view of the columns its page shows, over the folder of its rows (`file.folder`). Each row is a note whose properties are typed from Notion's `property-row-*` classes: text, number, check box, date or date and time, lists, links to pages (relations) and attachments (files), `Tags` as tags. The types join the vault's `.obsidian/types.json` through the destination, which keeps every type already there and says which. A row the database's CSV holds without a page in the export becomes a note of its properties. An inline database is embedded where the page had it (`![[Tasks.base]]`).
- Attachments are copied next to the pages that hold them, piece by piece, their names decoded when Notion left percent escapes in them.
- A Markdown export is refused with a message saying to export again as HTML.

The import report lists every note, base and attachment written, and what was simplified, left out (with the entries refused because their path or link could reach outside the export) or failed, with a link to each note.

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

Swift Testing, on macOS and Linux, and a WebAssembly build of `ImporterCore` and `NotionImport`, for every push. Each format is tested on material made for the purpose or published under a license that allows it, never on personal notes. Notion's HTML import is tested on Obsidian Importer's own test exports (`Tests/Fixtures/Notion`), compared file by file with an expected vault and line by line with upstream's expected notes, every difference explained, and on exports made by the tests for databases, CSV rows, nested parts, long titles, names already in the vault and paths that leave the export.

## Known limits

- Foundation makes a WebAssembly module of about 53.6 MB, where the standard library alone gives 5.6 MB (Graphite's section 7 spike). The core uses `Data`, `FileManager` and `URL`: moving the disk types (`FolderImportDestination`, `FileRandomAccessSource`, `FolderTemporaryStorage`, `ExportFileTree.reading(folder:)`) to a host target and the rest to `[UInt8]` is the way to the smaller module.
- Pages are read whole (refused over 256 MB each), attachments in 64 KB pieces. Real exports of 139 MB import in about 8 s with 160 MB of memory at most on a Mac.
- Importing again writes beside the earlier import (`Course 2.md`), never over it. Updating only the notes nobody edited is planned with the API import.
