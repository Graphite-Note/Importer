<!--
File: Design.md
---------------
Layer: Documentation
Description: How the Importer is built: its layers, what the host provides, how it reaches Graphite (linked first,
             a downloadable WebAssembly plugin later), how Notion is read and what it does better than Obsidian's
             Importer.

Authors: Bahey Shalash
Version: 0.8
Date: 28/11/2026
-->

# Design

Decided 2026-11-26: the importers are written in Swift in this repository instead of forking Obsidian's JavaScript Importer. Notion first, the other formats after. Graphite links the package first and later loads it as a downloadable plugin compiled to WebAssembly.

## Aims

1. **Ordinary files.** An import is a folder of Markdown notes, `.base` files and attachments that Obsidian and Graphite read alike. Nothing needs the importer afterwards.
2. **Nothing lost in silence.** Every page and database ends in the import report, a note in the import's folder that says what was converted, what was simplified (a column layout flattened, a synced block copied, a formula function Bases lacks) and what was left out, with a link to each note.
3. **Bounded memory.** An export of several GB is read entry by entry from the picked file, never loaded whole. Attachments are copied in pieces.
4. **Never overwrite.** A destination refuses to replace a file. Importing again updates only notes the importer wrote and nobody edited since.
5. **One code base everywhere.** The importers use the Swift standard library alone (since 0.2.0: no Foundation, no Apple frameworks, no Dispatch), within what Embedded Swift compiles, so the same code runs in the Mac and iPad apps, in tests on Linux, and as a WebAssembly plugin of under a megabyte. Only `ImporterFileSystem`, which reads and writes files on disk for the hosts that link the package, uses Foundation.

## Layers

| Target | Holds |
| --- | --- |
| `ImporterCore` | Vault file names (`VaultFileName`), the names taken in a folder (`VaultFolderNames`), vault paths (`VaultPath`), the destination (`ImportDestination`). The source read by range (`RandomAccessSource`), zip archives with zip64 (`ZipArchive`), a DEFLATE decoder (`Inflater`) and CRC-32, the files of an export across its parts and nested zips (`ExportFileTree`), temporary storage for compressed nested zips (`TemporaryStorage`). An HTML reader (`HTMLDocument`), CSV tables (`CSVTable`). The model of a note (`MarkdownBlock`, `MarkdownInline`) and its writer (`MarkdownWriter`), front matter and property types (`FrontMatter`, `PropertyType`), bases (`BaseFile`), the import report (`ImportReport`). The text functions the importers took from Foundation, written for the standard library (`TextFunctions`: trimming, replacing, splitting and finding text scalar by scalar, percent escapes, web addresses), each tested against Foundation's. |
| `NotionImport` | Notion's export names (`NotionExportEntryName`), the HTML export (`NotionHTMLImporter`, `NotionVaultPlan`, `NotionPageReader`, `NotionPropertyReader`, `NotionDateParser`). Notion's API (`NotionAPIClient`, `NotionAPIImporter`, `NotionAPIPageReader`, `NotionAPIPropertyReader`, `NotionAPIBaseWriter`), its formulas and rollups in Bases' formula language (`NotionFormulaConverter`, `NotionRollupConverter`). |
| `ImporterFileSystem` | Files on disk, with Foundation: a file read by range (`FileRandomAccessSource`), a vault folder (`FolderImportDestination`), temporary files in a folder (`FolderTemporaryStorage`), an unpacked export (`ExportFileTree.reading(folder:)`). For the hosts that link the package, the command and the tests. |
| `ImporterCommand` | The `importer` command, for manual runs: imports into a folder on disk. |
| `Plugin/` (a package of its own) | `ImporterWasm`, the WebAssembly module's exports and host calls, and the JavaScript plugin around it. |

A format reads its source into a small model of pages, blocks, properties and databases, then one writer per output kind turns that model into files. Formats share the writers, so Markdown, links and bases are written the same way whatever the source.

## What the host provides

The importer opens no file and sends no request on its own. The host passes:

- **The source** to read: random access to the picked export (read a range of bytes, the size), so a zip's central directory is read first and each entry is inflated as it is converted.
- **The destination** (`ImportDestination`): make a folder, write a new file, list a folder. Graphite writes through its coordinated vault writes, so iCloud and the index see each file once. `FolderImportDestination` writes a folder on disk, for tests and tools. The plugin writes through the plugin API (`vault.createBinary`, which refuses an existing file).
- **The transport**, for API imports: send a request, receive the answer. Graphite uses `URLSession` with the token from the Keychain. The WebAssembly build passes requests to the plugin runtime's `requestUrl`.
- **Temporary storage** (`TemporaryStorage`), for the few bytes that must be read again by range: a `Part-N` zip compressed inside the download is inflated there before its central directory is read. A zip stored inside another is read where it lies.
- **Progress and cancellation**: the importer reports pages done and pages left, and stops at the next page when its task is cancelled, leaving a usable partial import and its report.

## Reaching Graphite

1. **Linked.** Graphite depends on this package with an exact version, as it depends on MermaidDiagrams. Import › From Notion… opens a native sheet. Nothing of the importer is made until that sheet opens, so it costs nothing at launch or at rest.
2. **Downloadable.** Apple's guideline 2.5.2 refuses downloaded native code on iOS, but code run by WebKit is allowed, and Graphite's community-plugin runtime is a WKWebView. The package compiled to WebAssembly with the Swift SDK for WebAssembly, plus a small JavaScript plugin around it, becomes a plugin installed from Graphite's plugin list. Once it works on the iPad and the Mac, Graphite drops the linked copy and the app shrinks by the importer's size.

   The module (`Plugin/`) is built with Embedded Swift for `wasm32-unknown-wasip1` as a WASI reactor: 890 KB, 347 KB gzip, 258 KB brotli, against 6.3 MB (1.9 MB gzip) with the whole standard library and 53.6 MB with Foundation (Graphite's section 7 spike). It is carried inside the plugin's `main.js`, as plugins are installed from `main.js` and `manifest.json` alone. Each read, write and request is one host call (`importer_host.call`) that JavaScript answers later through `importer_resume`, so the import's async Swift code waits on the web view without blocking it. The picked files are read by range with `Blob.slice`, compressed `Part-N` zips are inflated into blobs the web view may keep on disk, and the vault is written through the plugin API. A file of up to 16 MB is written whole when its last piece arrives. A larger one is added in pieces of 16 MB with `adapter.appendBinary` to a hidden file beside it (`.week-1.mp4.notion-import-part-3`), renamed to its place once complete, and removed if the import ends first, so no write exceeds what a host accepts in one message (64 MB in Graphite) and nothing half written takes a file's name. An app whose adapter has no `appendBinary` gets every file whole.

## Notion

### From the HTML export

Notion's export is a zip (a zip of `Part-N` zips for large workspaces), everything inside a folder `Export-<identifier>` that the import leaves out. Each page is `<title> <identifier>.html`, its subpages in a folder of the same name, each database's rows in the folder of its page, with a `.csv` and an `_all.csv`. Exports whose files were renamed without identifiers are read too: a page is then known by the identifier in its `article` element and linked to by its path.

The import reads every page twice. The first pass keeps each page's whole title (the file name holds a shortened copy), whether it is a database, its headings, and the dates of its properties (to tell day-first from month-first dates). The vault places are then claimed, folder by folder, against the names already in the vault: a page's note and the folder of its subpages share one name (`Week 1.md` and `Week 1/`), a second page of the same title gets `Week 1 2`. Only then is each page converted and written, so every link resolves by page identifier, whatever its file was called. A link names the note alone when no other file of the import has its name, else its vault path.

- Pages become notes, their icon as the `icon` property and their cover as `banner` (a link to the copied picture, or its web address), their description as the first paragraph. `banner` is the property Graphite draws a cover from, and the one the Banners and Pixel Banner plugins read in Obsidian. Obsidian's Importer writes `cover`, which neither draws.
- Blocks: headings, paragraphs, lists, to-dos, quotes, code with its language in the highlighter's name, equations as `$…$` and `$$…$$`, simple tables, dividers, images and files (embedded when in the export), bookmarks and embeds as links, links to pages as wiki links, the table of contents nested by level. Callouts keep their emoji in the title, their type taken from the icon (`[!tip]` for a light bulb, `[!warning]` for a warning sign, `[!info]` for Notion's info icon, `[!note]` otherwise). Toggles become folded callouts. Toggle headings stay headings: headings fold in Obsidian and Graphite, and the links to them keep working. Columns are flattened, one after the other, and reported. Synced blocks reach the HTML export as ordinary blocks, so they are copied without a mark to report.
- Background colors become highlights, as do text colors other than gray, and a heading's color highlights its text. Other blocks' colors are dropped and counted in the report. Notion's line break before a change of style, right after a line break, is dropped. A date mention is its date, without Notion's `@`.
- Text is written so that it reads as Notion shows it. Spaces at the edges of a style or a link's label go outside it, so that the words beside it stay apart. Punctuation at a style's edge goes outside it where a letter touches the delimiter, and a style holding only punctuation or spaces is its text, as CommonMark (and Obsidian) would otherwise show the asterisks. A link's label escapes its own brackets (`[\[3\]](…)`, not a wiki link). A bare address is written bare only where an autolink reads it whole, else between `<` and `>`. `$` is escaped only on a line where two could pair into math, `#` only where it starts a tag (after a space, not inside an address). A rule opening a note is `***`, as `---` there would open its properties. A list item without text keeps its place, its marker alone.
- A picture or file held inside the page (a `data:` address) is written beside the note and embedded. A picture the export lacks is marked in its place, `_(picture not in the export: name)_`, and reported. A wiki link's text keeps no style, and losing a code style there is reported.
- A database's page becomes a base: a table view of the columns its page shows, over the folder its rows are in (`file.folder`), whatever the page's file is called. A database whose rows the export lacks (they link to notion.so) is a note with its table as a Markdown table, reported. Each row is a note whose properties are typed from Notion's `property-row-*` classes: text, number, check box, date or date and time, lists, links to pages (relations) and attachments (files), `Tags` as tags. The types join the vault's `.obsidian/types.json` through the destination, which keeps every type already there and says which. A row the database's CSV holds without a page in the export becomes a note of its properties. An inline database is embedded where the page had it (`![[Tasks.base]]`).
- Attachments are copied next to the pages that hold them, piece by piece, their names decoded when Notion left percent escapes in them.
- A Markdown export is refused with a message saying to export again as HTML.
- A page the export holds twice (a backup folder beside the original) is imported once: the copy the other pages link to, the other copies reported.
- A number Notion shows formatted is a number: `15%` as 0.15 (Notion keeps the fraction), `£42,000.00` as 42000, with the format reported. One that cannot be read is text, typed as text.
- Files are named as the vault paths spell them, composed (`Café`), where Foundation's file addresses would decompose them on Apple's systems.

The import report lists every note, base and attachment written, and what was simplified, left out (with the entries refused because their path or link could reach outside the export) or failed, with a link to each note.

### From the API

An internal integration's token (`ntn_…`), kept by the host (the Keychain in Graphite), never seen by the importer: the host's transport adds it to requests marked for Notion's API, and never to a file's address. Requests keep to Notion's limit of 3 a second after a burst of 10, wait as long as a 429's `Retry-After` says, and wait longer each time on a 5xx or a lost network, for up to 15 minutes before giving up (`NotionAPIClient`, Notion-Version `2025-09-03`, with data sources). Its JSON is read by `JSONValue`, standard library only.

- Discovery: `POST /v1/search` lists the pages and data sources shared with the integration, `GET /v1/databases/{id}` each database. Pages nest as in Notion, a page inside a block going up to the page that holds the block. A chosen page or database takes everything inside it.
- Pages (`NotionAPIPageReader`): blocks read page by page with their children into the same Markdown model as the HTML export, so notes are written the same way: rich text with its marks, links and mentions, lists and to-dos, toggles as folded callouts, toggle headings as headings, callouts by icon, code, math, tables, bookmarks, files, child pages and databases as links and embeds, synced blocks copied, columns flattened, a table of contents from the page's headings, AI meeting notes with their summary, notes and transcript. Each note has `notion-id`, its emoji icon as `icon` and its cover as `banner`: a cover from the web as its address, one uploaded to Notion downloaded beside the note and linked.
- Databases (`NotionAPIBaseWriter`): one base per database over its rows' folder, with the first data source's properties. Table, board, gallery and list views become table, Kanban, cards and list views, with the properties each shows, a board's groups and their order, sorts, covers, and filters of one property each. Calendar, timeline and chart views become table views, reported. Formulas Bases can compute become the base's formulas (`NotionFormulaConverter`, its function table after Obsidian Importer's `formula-converter.ts`). Rollups become formulas over the notes their relation links to (`NotionRollupConverter`: counts, sums, averages, medians, extremes, ranges, unique values, checked shares), reading the related data source's properties to know its title and its tags. The formulas and rollups Bases cannot compute are written as their values and reported.
- Linked databases (a database showing another's data source, which the search does not list and a page's block names): no base of their own. Their views are added to the base of the database they show, each named after the linked database too (`Board (This week)`), and the page embeds that base on its first such view (`![[Tasks.base#Board (This week)]]`). Pages are written before databases so that every linked view is known when a base is written. A database Notion refuses to give is reported and its embed kept as its title.
- Rows (`NotionAPIPropertyReader`): the HTML import's types, relations as links inside the import and as titles outside it.
- Files Notion holds are downloaded while their page is written, as their addresses expire after about an hour, into the page's folder, in ranges of 8 MB written piece by piece.
- A revoked token or Notion unreachable ends the import with what was written and a report that says why. A page unshared during the import is reported and the rest imported.

- Importing again (`NotionAPIImporter.updateImport`, into a destination that is also an `UpdatingImportDestination`): every import leaves `.notion-import.json` in its folder, each note's and base's path with the fingerprint of the bytes written (`ContentFingerprint`, 64-bit FNV-1a). An update finds the earlier notes by their `notion-id`, wherever they were moved in the folder, and writes each page and database where the earlier import put it. A file still holding what the earlier import wrote is replaced, the host checking it is still the same at that moment. A file changed in the vault since, or one whose fingerprint is not known, is kept and reported. New pages and databases are added beside, and a file already downloaded under its name is kept, so nothing is written twice.

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

Swift Testing, on macOS and Linux, and a WebAssembly build of `ImporterCore` and `NotionImport` and of the plugin's module (Embedded Swift and the standard library), each module importing the test exports in Node with the result compared byte for byte with the `importer` command's, for every push. Each format is tested on material made for the purpose or published under a license that allows it, never on personal notes. Notion's HTML import is tested on Obsidian Importer's own test exports (`Tests/Fixtures/Notion`), compared file by file with an expected vault and line by line with upstream's expected notes, every difference explained, and on exports made by the tests for databases, CSV rows, nested parts, long titles, names already in the vault and paths that leave the export.

## Known limits

- Embedded Swift has no weak references: there `HTMLNode.parent` is `unowned(unsafe)`, so a node must not outlive its document, which the importers never let happen. Embedded Swift also describes only the errors it is told of: a host's own error reaches the report as `ReportedError` with its words.
- Without `appendBinary` the plugin API writes a file whole, so the plugin holds an attachment in the web view's memory until its last piece, about twice its size at the write. With it, an attachment costs the web view about 16 MB at a time.
- Pages are read whole (refused over 256 MB each), attachments in 64 KB pieces. Real exports of 139 MB import in about 8 s with 160 MB of memory at most on a Mac.
- Importing the HTML export again writes beside the earlier import (`Course 2.md`), never over it. The API import updates an earlier import (above).
