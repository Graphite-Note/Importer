/**
 * File: FolderImportDestination.swift
 * -----------------------------------
 * Layer: File system
 * Description: An import destination that is a folder on disk, written with plain file operations, for tests, tools
 *              and hosts that need no coordination of their writes, its files named as the vault paths spell them.
 *
 * Authors: Bahey Shalash
 * Version: 0.6
 * Date: 28/11/2026
 */

import Foundation
import ImporterCore

/// A vault that is a folder on disk, written to directly.
public struct FolderImportDestination: ImportDestination {
    /// The vault's folder.
    public let vaultFolder: URL

    /// The path of the vault's property types, as Obsidian keeps them.
    public static let propertyTypesPath = VaultPath(components: [".obsidian", "types.json"])!

    public init(vaultFolder: URL) {
        self.vaultFolder = vaultFolder
    }

    #if os(WASI)
    public func createFolder(at path: VaultPath) async throws {
        try FileManager.default.createDirectory(at: url(of: path), withIntermediateDirectories: true)
    }

    public func writeNewFile(_ contents: [UInt8], at path: VaultPath) async throws {
        let fileURL = url(of: path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw ImportDestinationError.fileAlreadyExists(path)
        }
        try Data(contents).write(to: fileURL, options: .withoutOverwriting)
    }

    public func createNewFile(at path: VaultPath) async throws -> any ImportFileWriting {
        let fileURL = url(of: path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw ImportDestinationError.fileAlreadyExists(path)
        }
        try Data().write(to: fileURL, options: .withoutOverwriting)
        return FolderImportFileWriter(handle: try FileHandle(forWritingTo: fileURL))
    }
    #else
    // Files and folders are made through their paths as strings: Foundation's file URLs hand Apple's systems names
    // decomposed (`Café` as `Cafe` and a combining accent), which other systems, sync and links take for other names.
    public func createFolder(at path: VaultPath) async throws {
        try FileManager.default.createDirectory(at: vaultFolder, withIntermediateDirectories: true)
        var current = vaultFolder.path
        for name in path.components {
            current += "/" + name
            if mkdir(current, 0o755) != 0, errno != EEXIST { throw FolderImportDestinationError.systemCall("mkdir", errno, path) }
        }
    }

    public func writeNewFile(_ contents: [UInt8], at path: VaultPath) async throws {
        let handle = try createFile(at: path)
        try FileDescriptorIO.write(handle.fileDescriptor, contents)
        try handle.close()
    }

    public func createNewFile(at path: VaultPath) async throws -> any ImportFileWriting {
        FolderImportFileWriter(handle: try createFile(at: path))
    }

    /// The file `path`, made empty and open for writing, never one already there.
    private func createFile(at path: VaultPath) throws -> FileHandle {
        let descriptor = open(filePath(of: path), O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw ImportDestinationError.fileAlreadyExists(path) }
            throw FolderImportDestinationError.systemCall("open", errno, path)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    #endif

    public func names(inFolderAt path: VaultPath) async throws -> [String] {
        let folderURL = url(of: path)
        // A missing folder, or a file in its place, has no names in it.
        guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [] }
        // Composed, as vault paths are, whichever way the files were named.
        return try FileManager.default.contentsOfDirectory(atPath: folderURL.path).map { $0.precomposedStringWithCanonicalMapping }
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
        #if os(WASI)
        // WebAssembly's file system has no temporary files to write through.
        try data.write(to: fileURL)
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        return conflicting
    }

    fileprivate func url(of path: VaultPath) -> URL {
        path.components.reduce(vaultFolder) { folder, name in folder.appendingPathComponent(name) }
    }

    /// The path of `path` as a string, its names as the vault path spells them.
    fileprivate func filePath(of path: VaultPath) -> String {
        ([vaultFolder.path] + path.components).joined(separator: "/")
    }
}

/// A file operation of a folder destination the system refused.
public enum FolderImportDestinationError: Error, Equatable, CustomStringConvertible {
    case systemCall(String, Int32, VaultPath)

    public var description: String {
        switch self {
        case .systemCall(let call, let code, let path):
            return "\(path) could not be written (\(call) failed with error \(code))"
        }
    }
}

/// A folder updated by a later import: nothing else writes it meanwhile, so a replacement checks the file just before.
extension FolderImportDestination: UpdatingImportDestination {
    public func readFile(at path: VaultPath) async throws -> [UInt8]? {
        let fileURL = url(of: path)
        guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return Array(try Data(contentsOf: fileURL))
    }

    public func replaceFile(at path: VaultPath, expecting expected: [UInt8], with contents: [UInt8]) async throws {
        guard try await readFile(at: path) == expected else { throw ImportUpdateError.changedSinceRead(path) }
        #if os(WASI)
        try Data(contents).write(to: url(of: path))
        #else
        // Written beside it, then renamed over it, under the name the vault path spells.
        let target = filePath(of: path)
        let temporary = target + ".importer-\(UInt64.random(in: 0...UInt64.max))"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw FolderImportDestinationError.systemCall("open", errno, path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try FileDescriptorIO.write(handle.fileDescriptor, contents)
            try handle.close()
        } catch {
            unlink(temporary)
            throw error
        }
        if rename(temporary, target) != 0 {
            let code = errno
            unlink(temporary)
            throw FolderImportDestinationError.systemCall("rename", code, path)
        }
        #endif
    }

    public func filePaths(inFolderAt path: VaultPath) async throws -> [VaultPath] {
        let folderURL = url(of: path)
        guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [] }
        var paths: [VaultPath] = []
        for relative in try FileManager.default.subpathsOfDirectory(atPath: folderURL.path).sorted() {
            let components = relative.split(separator: "/").map(String.init)
            let fileURL = folderURL.appendingPathComponent(relative)
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                let filePath = VaultPath(components: path.components + components)
            else { continue }
            paths.append(filePath)
        }
        return paths
    }
}

/// A file of a folder destination written piece by piece.
actor FolderImportFileWriter: ImportFileWriting {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func append(_ bytes: [UInt8]) throws {
        #if os(WASI)
        try handle.write(contentsOf: bytes)
        #else
        try FileDescriptorIO.write(handle.fileDescriptor, bytes)
        #endif
    }

    func close() throws {
        try handle.close()
    }
}
