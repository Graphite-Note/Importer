/**
 * File: FolderImportDestination.swift
 * -----------------------------------
 * Layer: Core
 * Description: An import destination that is a folder on disk, written with plain file operations, for tests, tools
 *              and hosts that need no coordination of their writes.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

/// A vault that is a folder on disk, written to directly.
public struct FolderImportDestination: ImportDestination {
    /// The vault's folder.
    public let vaultFolder: URL

    public init(vaultFolder: URL) {
        self.vaultFolder = vaultFolder
    }

    public func createFolder(at path: VaultPath) async throws {
        try FileManager.default.createDirectory(at: url(of: path), withIntermediateDirectories: true)
    }

    public func writeNewFile(_ contents: Data, at path: VaultPath) async throws {
        let fileURL = url(of: path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw ImportDestinationError.fileAlreadyExists(path)
        }
        try contents.write(to: fileURL, options: .withoutOverwriting)
    }

    public func names(inFolderAt path: VaultPath) async throws -> [String] {
        let folderURL = url(of: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isFolder), isFolder.boolValue else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
    }

    private func url(of path: VaultPath) -> URL {
        path.components.reduce(vaultFolder) { folder, name in folder.appendingPathComponent(name) }
    }
}
