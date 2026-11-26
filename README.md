<!--
File: README.md
---------------
Layer: Documentation
Description: What the Importer is, its state, how to use it and where its plan lives.

Authors: Bahey Shalash
Version: 0.1
Date: 26/11/2026
-->

# Importer

Turns the exports of other note apps into an ordinary vault: Markdown notes, [Obsidian Bases](https://help.obsidian.md/bases) for databases, and attachments as files, so the result works the same in [Graphite](https://github.com/Graphite-Note/Graphite) and in Obsidian. Written in Swift, with no dependency but Foundation. It knows no app: the host gives it the export to read, the place to write and, for imports over the network, the way to send requests.

Notion comes first, from its HTML export and from its API. The other formats of Obsidian's [Importer](https://github.com/obsidianmd/obsidian-importer) follow (Evernote, Apple Notes, Bear, OneNote, Logseq, Roam, Google Keep and more).

## State

Early. The package holds the shared ground every format needs (vault file names, vault paths that cannot leave the vault, the destination imports write to) and the reading of Notion's export names. **No format imports anything yet.** [docs/Design.md](docs/Design.md) describes the design, and the plan with its open items is [Docs/Notion-import-todo.md](https://github.com/Graphite-Note/Graphite/blob/main/Docs/Notion-import-todo.md) in Graphite.

## Using it

```swift
.package(url: "https://github.com/Graphite-Note/Importer.git", branch: "main")
```

and the product `Importer` in a target's dependencies. Releases with version tags come once Notion's HTML export imports.

Tests: `swift test`.

## License

MIT (`LICENSE`). Conversion rules ported from Obsidian Importer, Copyright (c) 2023 Obsidian, MIT licensed, keep its notice (`OBSIDIAN-IMPORTER-LICENSE`).
