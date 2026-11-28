/**
 * File: NotionVaultPlan.swift
 * ---------------------------
 * Layer: Notion
 * Description: The files of Notion's export sorted into pages, databases' tables and attachments, and the place each
 *              takes in the vault, decided before anything is written, so that every link resolves by page
 *              identifier whatever the names Notion shortened.
 *
 * Authors: Bahey Shalash
 * Version: 0.3
 * Date: 28/11/2026
 */

import ImporterCore

/// The files of Notion's HTML export, sorted.
struct NotionExport: Sendable {
    /// A page of the export.
    struct Page: Sendable {
        var identifier: String
        var file: ExportFile
        /// The title the file's name gives, for a page whose own title cannot be read.
        var titleFromName: String
    }

    /// The pages, folders before the folders inside them.
    var pages: [Page]
    /// The files that are neither pages nor database tables, with their paths in the export.
    var attachments: [ExportFile]
    /// HTML files whose names hold no page identifier: pages of exports whose files were renamed, told apart from
    /// other HTML files by the page identifier inside them, once they are read.
    var unnamedHTMLFiles: [ExportFile]
    /// The CSV of each database, by the identifier of its page (all its rows when Notion gives `_all.csv`).
    var csvFiles: [String: ExportFile]
    /// Every folder of the export, by its path.
    var folders: Set<[String]>
    /// Pages whose identifier an earlier file of the export already has: copies of a page (a backup folder beside the
    /// original), one of which is imported (`chooseAmongCopies`).
    var duplicatePages: [Page] = []

    /// The export of `tree`. The folder Notion puts everything in (`Export-<identifier>`) is left out of the paths, so
    /// that the parts of a large export, each with that folder, add up to one tree.
    init(_ tree: ExportFileTree) throws {
        var files = tree.files.filter { !$0.pathComponents.isEmpty }
        var sharedDepth = 0
        while let first = files.first, first.pathComponents.count > sharedDepth + 1,
            files.allSatisfy({ $0.pathComponents.count > sharedDepth + 1 && $0.pathComponents[sharedDepth] == first.pathComponents[sharedDepth] }),
            NotionExportEntryName(first.pathComponents[sharedDepth]) == nil
        {
            sharedDepth += 1
        }
        files = files.map { $0.relocated(to: Array($0.pathComponents.dropFirst(sharedDepth))) }

        let names = files.map { NotionExportEntryName($0.name) }
        let htmlCount = names.filter { $0?.pathExtension == "html" }.count
        let markdownCount = names.filter { $0?.pathExtension == "md" }.count
        let unnamedHTMLCount = zip(files, names).filter { $0.1 == nil && $0.0.name.lowercased().hasSuffix(".html") }.count
        if htmlCount == 0, markdownCount > 0 {
            throw NotionImportError.markdownExport
        }
        if htmlCount == 0, unnamedHTMLCount == 0 {
            throw NotionImportError.noPages
        }

        var pages: [Page] = []
        var attachments: [ExportFile] = []
        var csvFiles: [String: ExportFile] = [:]
        var unnamedHTMLFiles: [ExportFile] = []
        var seenPages: Set<String> = []
        var folders: Set<[String]> = []
        for (file, name) in zip(files, names) {
            for depth in 1..<max(1, file.pathComponents.count) {
                folders.insert(Array(file.pathComponents.prefix(depth)))
            }
            switch name?.pathExtension {
            case "html"?:
                if let name {
                    let page = Page(identifier: name.pageIdentifier, file: file, titleFromName: name.title)
                    if seenPages.insert(name.pageIdentifier).inserted {
                        pages.append(page)
                    } else {
                        duplicatePages.append(page)
                    }
                }
            case "csv"?:
                if let name, name.isAllRowsTable || csvFiles[name.pageIdentifier] == nil {
                    csvFiles[name.pageIdentifier] = file
                }
            default:
                if file.name.lowercased().hasSuffix(".html") {
                    unnamedHTMLFiles.append(file)
                } else {
                    attachments.append(file)
                }
            }
        }
        self.pages = pages
        self.attachments = attachments
        self.csvFiles = csvFiles
        self.folders = folders
        self.unnamedHTMLFiles = unnamedHTMLFiles
        sortPages()
    }

    /// Takes the HTML files `found` as pages with their identifiers. The other unnamed HTML files are attachments, but
    /// for Notion's own index of the export, which is no page of the workspace.
    mutating func adoptUnnamedPages(_ found: [(file: ExportFile, identifier: String)]) {
        var seen = Set(pages.map({ $0.identifier }))
        var adopted: Set<String> = []
        for (file, identifier) in found {
            let page = Page(identifier: identifier, file: file, titleFromName: String(file.name.dropLast(".html".count)))
            if seen.insert(identifier).inserted {
                pages.append(page)
            } else {
                duplicatePages.append(page)
            }
            adopted.insert(file.path)
        }
        for file in unnamedHTMLFiles where !adopted.contains(file.path) && file.pathComponents != ["index.html"] {
            attachments.append(file)
        }
        unnamedHTMLFiles = []
        sortPages()
    }

    /// Keeps, of each page the export holds more than once, the copy that `score` rates highest (the one the other
    /// pages link to), the first in the export's order on a tie, and gives each copy left out with the one kept.
    mutating func chooseAmongCopies(score: (ExportFile) -> Int) -> [(kept: Page, leftOut: Page)] {
        guard !duplicatePages.isEmpty else { return [] }
        var copies: [String: [Page]] = [:]
        for page in duplicatePages { copies[page.identifier, default: []].append(page) }
        var decisions: [(kept: Page, leftOut: Page)] = []
        for (index, page) in pages.enumerated() {
            guard let others = copies[page.identifier] else { continue }
            var kept = page
            for other in others where score(other.file) > score(kept.file) { kept = other }
            pages[index] = kept
            for candidate in [page] + others where candidate.file.path != kept.file.path {
                decisions.append((kept, candidate))
            }
        }
        duplicatePages = []
        sortPages()
        return decisions
    }

    private mutating func sortPages() {
        pages.sort { left, right in
            left.file.pathComponents.count != right.file.pathComponents.count
                ? left.file.pathComponents.count < right.file.pathComponents.count
                : left.file.path < right.file.path
        }
    }
}

/// Where each page, database and attachment of an export goes in the vault, and how links to them are written.
struct NotionVaultPlan: NotionLinkResolving, Sendable {
    /// The place of one page.
    struct Placement: Sendable {
        /// The note, or the base of a database.
        var path: VaultPath
        /// The folder of the page's subpages, attachments or rows, when it has any.
        var childFolder: VaultPath?
        var isBase: Bool
    }

    /// The import's folder.
    let rootFolder: VaultPath
    /// The folders to make, outer folders first.
    private(set) var foldersToCreate: [VaultPath] = []
    private var placements: [String: Placement] = [:]
    private var titles: [String: String] = [:]
    private var pageIdentifiers: [String: String] = [:]
    private var headings: [String: [String: String]] = [:]
    private var attachmentPaths: [String: VaultPath] = [:]
    /// The attachments by the identifier of the innermost page folder holding them and their path from there, `nil`
    /// for a key two attachments share: for links whose folder names differ from the export's own.
    private var attachmentPathsByPage: [String: VaultPath?] = [:]
    private var linkTargets: [VaultPath: String] = [:]
    private var folderNames: [VaultPath: VaultFolderNames] = [:]

    init(export: NotionExport, summaries: [String: NotionPageSummary], destination: any ImportDestination,
         root: VaultPath) async throws {
        rootFolder = root
        var pagesInFolder: [[String]: [NotionExport.Page]] = [:]
        for page in export.pages {
            pagesInFolder[Array(page.file.pathComponents.dropLast()), default: []].append(page)
        }
        var attachmentsInFolder: [[String]: [ExportFile]] = [:]
        for attachment in export.attachments {
            attachmentsInFolder[Array(attachment.pathComponents.dropLast()), default: []].append(attachment)
        }
        var subfolders: [[String]: [String]] = [:]
        for folder in export.folders {
            subfolders[Array(folder.dropLast()), default: []].append(folder.last ?? "")
        }

        var vaultFolderOf: [[String]: VaultPath] = [[]: root]
        var queue: [[String]] = [[]]
        var created: [VaultPath] = [root]
        while !queue.isEmpty {
            let exportFolder = queue.removeFirst()
            guard let vaultFolder = vaultFolderOf[exportFolder] else { continue }
            var names = VaultFolderNames(existingNames: try await destination.names(inFolderAt: vaultFolder))
            var placedSubfolders: Set<String> = []
            for page in pagesInFolder[exportFolder] ?? [] {
                let summary = summaries[page.identifier]
                let title = summary?.title ?? page.titleFromName
                let childName = String(page.file.name.dropLast(".html".count))
                let hasChildren = export.folders.contains(exportFolder + [childName])
                // A database becomes a base over its rows, when the export holds them; else a note with its table.
                let isBase = summary?.isDatabase == true && (summary?.hasRowsInExport == true || export.csvFiles[page.identifier] != nil)
                let pathExtension = isBase ? "base" : "md"
                let stem = names.claimStem(VaultFileName.stem(forTitle: title),
                                           withEachOf: hasChildren ? [pathExtension, nil] : [pathExtension])
                guard let path = vaultFolder.appending("\(stem).\(pathExtension)") else { continue }
                var placement = Placement(path: path, childFolder: nil, isBase: pathExtension == "base")
                if hasChildren, let childFolder = vaultFolder.appending(stem) {
                    placement.childFolder = childFolder
                    vaultFolderOf[exportFolder + [childName]] = childFolder
                    placedSubfolders.insert(childName)
                }
                placements[page.identifier] = placement
                pageIdentifiers[NotionVaultPlan.key(page.file.pathComponents)] = page.identifier
                titles[page.identifier] = title
                headings[page.identifier] = summary?.headingTextByBlock ?? [:]
            }
            for subfolder in (subfolders[exportFolder] ?? []).sorted() where !placedSubfolders.contains(subfolder) {
                let title = NotionExportEntryName(subfolder)?.title ?? subfolder
                let stem = names.claimStem(VaultFileName.stem(forTitle: title), withEachOf: [nil])
                if let childFolder = vaultFolder.appending(stem) {
                    vaultFolderOf[exportFolder + [subfolder]] = childFolder
                }
            }
            for attachment in attachmentsInFolder[exportFolder] ?? [] {
                let (stem, pathExtension) = NotionVaultPlan.attachmentName(attachment.name)
                let name = names.claim(stem: stem, pathExtension: pathExtension)
                if let path = vaultFolder.appending(name) {
                    attachmentPaths[NotionVaultPlan.key(attachment.pathComponents)] = path
                    if let key = NotionVaultPlan.pageKey(attachment.pathComponents) {
                        attachmentPathsByPage[key] = attachmentPathsByPage[key] == nil ? path : .some(nil)
                    }
                }
            }
            folderNames[vaultFolder] = names
            for subfolder in (subfolders[exportFolder] ?? []).sorted() {
                let child = exportFolder + [subfolder]
                if let vaultChild = vaultFolderOf[child] {
                    created.append(vaultChild)
                    queue.append(child)
                }
            }
        }
        foldersToCreate = created.filter { !$0.components.isEmpty }

        // A link names the note alone when no other file of the import has its name, else its path.
        var counts: [String: Int] = [:]
        let allPaths = placements.values.map({ $0.path }) + attachmentPaths.values
        for path in allPaths { counts[NotionVaultPlan.linkKey(path), default: 0] += 1 }
        for path in allPaths {
            let isNote = path.name.hasSuffix(".md")
            let name = isNote ? String(path.name.dropLast(3)) : path.name
            if counts[NotionVaultPlan.linkKey(path)] == 1 {
                linkTargets[path] = name
            } else {
                let full = path.description
                linkTargets[path] = isNote ? String(full.dropLast(3)) : full
            }
        }
    }

    private static func linkKey(_ path: VaultPath) -> String {
        (path.name.hasSuffix(".md") ? String(path.name.dropLast(3)) : path.name).lowercased()
    }

    private static func key(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    /// The identifier of the innermost folder of `components` named after a page, followed by the path from it.
    private static func pageKey(_ components: [String]) -> String? {
        let folders = components.dropLast()
        guard let index = folders.lastIndex(where: { NotionExportEntryName($0).map { $0.pathExtension == nil } ?? false }),
            let name = NotionExportEntryName(components[index])
        else { return nil }
        return ([name.pageIdentifier] + components[(index + 1)...]).joined(separator: "/")
    }

    /// The name an attachment is copied under: Notion's name, with the percent escapes some names keep decoded,
    /// cleaned as every vault name is.
    static func attachmentName(_ name: String) -> (stem: String, pathExtension: String?) {
        var readable = name
        if let decoded = name.percentDecoded, decoded != name, !decoded.contains("/"),
            !decoded.unicodeScalars.contains(where: { $0.value < 0x20 })
        {
            readable = decoded
        }
        var stem = readable
        var pathExtension: String?
        if let dot = readable.lastIndex(of: "."), dot != readable.startIndex {
            let candidate = readable[readable.index(after: dot)...]
            if !candidate.isEmpty, candidate.count <= 10, candidate.allSatisfy({ $0.isLetter || $0.isNumber }) {
                pathExtension = String(candidate)
                stem = String(readable[..<dot])
            }
        }
        return (VaultFileName.stem(forTitle: stem), pathExtension)
    }

    // MARK: Questions of the importer

    func placement(ofPage identifier: String) -> Placement? {
        placements[identifier]
    }

    func title(ofPage identifier: String) -> String? {
        titles[identifier]
    }

    func attachmentPath(atExportPath components: [String]) -> VaultPath? {
        attachmentPaths[NotionVaultPlan.key(components)]
    }

    /// Takes the report's name in the import's folder.
    mutating func claimReportName(_ name: String) -> String {
        var names = folderNames[rootFolder] ?? VaultFolderNames()
        let stem = names.claimStem(VaultFileName.stem(forTitle: name), withEachOf: ["md"])
        folderNames[rootFolder] = names
        return stem
    }

    /// Takes a name for the attachment `name` in `folder`, for files the plan did not place (held inside a page).
    mutating func claimAttachment(named name: String, in folder: VaultPath) -> VaultPath {
        var names = folderNames[folder] ?? VaultFolderNames()
        let (stem, pathExtension) = NotionVaultPlan.attachmentName(name)
        let claimed = names.claim(stem: stem, pathExtension: pathExtension)
        folderNames[folder] = names
        return folder.appending(claimed) ?? folder
    }

    /// Takes a note's name for `title` in `folder`, for notes the plan did not place (rows made from a CSV).
    mutating func claimNote(titled title: String, in folder: VaultPath) -> VaultPath {
        var names = folderNames[folder] ?? VaultFolderNames()
        let stem = names.claimStem(VaultFileName.stem(forTitle: title), withEachOf: ["md"])
        folderNames[folder] = names
        return folder.appending("\(stem).md") ?? folder
    }

    // MARK: NotionLinkResolving

    func target(ofPage identifier: String) -> NotionLinkTarget? {
        guard let placement = placements[identifier], let target = linkTargets[placement.path] else { return nil }
        return NotionLinkTarget(linkTarget: target, title: titles[identifier] ?? target, isBase: placement.isBase)
    }

    func attachmentTarget(atExportPath exportPath: [String]) -> String? {
        if let path = attachmentPaths[NotionVaultPlan.key(exportPath)] { return linkTargets[path] }
        // Some links are escaped twice.
        let decoded = exportPath.map { $0.percentDecoded ?? $0 }
        if let path = attachmentPaths[NotionVaultPlan.key(decoded)] { return linkTargets[path] }
        // Some exports were unpacked with another encoding, so their folder names no longer match their links: the
        // page identifier ending each folder name still does.
        for components in [exportPath, decoded] {
            if let key = NotionVaultPlan.pageKey(components), case .some(.some(let path)) = attachmentPathsByPage[key] {
                return linkTargets[path]
            }
        }
        return nil
    }

    func pageIdentifier(atExportPath exportPath: [String]) -> String? {
        pageIdentifiers[NotionVaultPlan.key(exportPath)]
            ?? pageIdentifiers[NotionVaultPlan.key(exportPath.map { $0.percentDecoded ?? $0 })]
    }

    func headingText(inPage pageIdentifier: String, block blockIdentifier: String) -> String? {
        headings[pageIdentifier]?[blockIdentifier]
    }
}
