/**
 * File: main.swift
 * ----------------
 * Layer: Command
 * Description: The `importer` command, for manual runs and checks on real exports: imports Notion's HTML export, a
 *              zip, several parts or an unpacked folder, into a vault folder on disk, and prints the report.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

import Foundation
import ImporterCore
import ImporterFileSystem
import NotionImport

let usage = """
    Usage: importer notion <export.zip | export folder> [more parts…] --vault <vault folder> [--into <folder in vault>]

    Imports Notion's HTML export into the vault, in the folder named by --into ("Notion" when not given), and prints the
    import report. Nothing already in the vault is replaced.
    """

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "notion" else {
    print(usage)
    exit(2)
}
arguments.removeFirst()
var sources: [String] = []
var vault: String?
var into = "Notion"
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--vault": vault = arguments.isEmpty ? nil : arguments.removeFirst()
    case "--into": into = arguments.isEmpty ? into : arguments.removeFirst()
    default: sources.append(argument)
    }
}
guard let vault, !sources.isEmpty, let folder = VaultPath(components: into.split(separator: "/").map(String.init)) else {
    print(usage)
    exit(2)
}

let vaultURL = URL(fileURLWithPath: vault)
let temporaryFolder = FileManager.default.temporaryDirectory.appendingPathComponent("importer-\(UUID().uuidString)")
do {
    let tree: ExportFileTree
    var isFolder: ObjCBool = false
    if sources.count == 1, FileManager.default.fileExists(atPath: sources[0], isDirectory: &isFolder), isFolder.boolValue {
        tree = try ExportFileTree.reading(folder: URL(fileURLWithPath: sources[0]))
    } else {
        let storage = try FolderTemporaryStorage(folder: temporaryFolder)
        tree = try await ExportFileTree.reading(zipArchives: try sources.map { try FileRandomAccessSource(url: URL(fileURLWithPath: $0)) },
                                                named: sources.map { URL(fileURLWithPath: $0).lastPathComponent },
                                                temporaryStorage: storage)
    }
    let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
    let year = Calendar(identifier: .gregorian).component(.year, from: Date())
    let options = NotionHTMLImportOptions(destinationFolder: folder,
                                          exportName: sources.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "),
                                          importDate: today, exportYear: year)
    let result = try await NotionHTMLImporter.importExport(tree, into: FolderImportDestination(vaultFolder: vaultURL), options: options)
    print(result.report.markdown)
    try? FileManager.default.removeItem(at: temporaryFolder)
} catch let error as NotionImportError {
    try? FileManager.default.removeItem(at: temporaryFolder)
    print(error.description)
    exit(1)
} catch {
    try? FileManager.default.removeItem(at: temporaryFolder)
    print("The import failed: \(error)")
    exit(1)
}
