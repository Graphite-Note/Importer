/**
 * File: FolderImportDestination.swift
 * -----------------------------------
 * Layer: Core
 * Description: An import destination that is a folder on disk, written with plain file operations, for tests, tools
 *              and hosts that need no coordination of their writes.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 26/11/2026
 */

import Foundation

/// A vault that is a folder on disk, written to directly.
public struct FolderImportDestination: ImportDestination {
    /// The vault's folder.
    public let vaultFolder: URL

    /// The path of the vault's property types, as Obsidian keeps them.
    public static let propertyTypesPath = VaultPath(components: [".obsidian", "types.json"])!

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

    public func createNewFile(at path: VaultPath) async throws -> any ImportFileWriting {
        let fileURL = url(of: path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw ImportDestinationError.fileAlreadyExists(path)
        }
        try Data().write(to: fileURL, options: .withoutOverwriting)
        return try FolderImportFileWriter(url: fileURL)
    }

    public func names(inFolderAt path: VaultPath) async throws -> [String] {
        let folderURL = url(of: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isFolder), isFolder.boolValue else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
    }

    public func assignPropertyTypes(_ types: [String: PropertyType]) async throws -> [String] {
        let fileURL = url(of: FolderImportDestination.propertyTypesPath)
        var document: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let contents = try Data(contentsOf: fileURL)
            guard let object = try? JSONSerialization.jsonObject(with: contents) as? [String: Any] else {
                throw ImportDestinationError.unreadablePropertyTypes(FolderImportDestination.propertyTypesPath)
            }
            document = object
        }
        guard var assigned = (document["types"] ?? [String: Any]()) as? [String: Any] else {
            throw ImportDestinationError.unreadablePropertyTypes(FolderImportDestination.propertyTypesPath)
        }
        var conflicting: [String] = []
        var changed = false
        for (name, type) in types.sorted(by: { $0.key < $1.key }) {
            if let existing = assigned.first(where: { $0.key.lowercased() == name.lowercased() }) {
                if (existing.value as? String) != type.rawValue { conflicting.append(name) }
                continue
            }
            assigned[name] = type.rawValue
            changed = true
        }
        guard changed else { return conflicting }
        document["types"] = assigned
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
        return conflicting
    }

    private func url(of path: VaultPath) -> URL {
        path.components.reduce(vaultFolder) { folder, name in folder.appendingPathComponent(name) }
    }
}

/// A file of a folder destination written piece by piece.
actor FolderImportFileWriter: ImportFileWriting {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ bytes: Data) throws {
        try handle.write(contentsOf: bytes)
    }

    func close() throws {
        try handle.close()
    }
}
