/**
 * File: VaultComparison.swift
 * ---------------------------
 * Layer: Tests
 * Description: Helpers for comparing an imported vault with the one expected: the files under a folder, a line
 *              difference between two notes written as a short list, and a temporary vault folder.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

/// A folder for one test's vault, removed by `remove()`.
public struct TemporaryVault {
    public let folder: URL

    public init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("importer-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The text of the file at `path`, names separated by "/".
    public func text(_ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    /// Whether a file or folder is at `path`.
    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
    }

    /// The paths of every file under the vault, sorted, names separated by "/".
    public func filePaths() -> [String] {
        relativeFilePaths(under: folder)
    }

    /// Removes the vault, unless `IMPORTER_KEEP_VAULTS=1` asks to keep it for a look, in which case its path is printed.
    public func remove() {
        if ProcessInfo.processInfo.environment["IMPORTER_KEEP_VAULTS"] == "1" {
            print("Vault kept at \(folder.path)")
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The paths of the files under `folder`, relative to it, sorted.
public func relativeFilePaths(under folder: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    let base = folder.standardizedFileURL.path
    var paths: [String] = []
    while let url = enumerator.nextObject() as? URL {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let path = url.standardizedFileURL.path
        paths.append(String(path.dropFirst(base.count + 1)))
    }
    return paths.sorted()
}

/// The lines of `new` that differ from `old`: each run of changes after `@@ <line in old>`, removed lines after "-",
/// added lines after "+". Empty when the texts are the same.
public func lineDifferences(from old: String, to new: String) -> String {
    let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let difference = newLines.difference(from: oldLines)
    var removed: Set<Int> = []
    var inserted: Set<Int> = []
    for change in difference {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }
    var output: [String] = []
    var oldIndex = 0
    var newIndex = 0
    var isInRun = false
    while oldIndex < oldLines.count || newIndex < newLines.count {
        if oldIndex < oldLines.count, removed.contains(oldIndex) {
            if !isInRun { output.append("@@ \(oldIndex + 1)") }
            isInRun = true
            output.append("- " + oldLines[oldIndex])
            oldIndex += 1
        } else if newIndex < newLines.count, inserted.contains(newIndex) {
            if !isInRun { output.append("@@ \(oldIndex + 1)") }
            isInRun = true
            output.append("+ " + newLines[newIndex])
            newIndex += 1
        } else {
            isInRun = false
            oldIndex += 1
            newIndex += 1
        }
    }
    return output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
}

/// Whether the tests are asked to write what they produce as the expected files (`IMPORTER_RECORD_EXPECTED=1`), after
/// a change of output that has been checked by hand.
public var isRecordingExpectedFiles: Bool {
    ProcessInfo.processInfo.environment["IMPORTER_RECORD_EXPECTED"] == "1"
}
