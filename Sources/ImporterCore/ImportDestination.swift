/**
 * File: ImportDestination.swift
 * -----------------------------
 * Layer: Core
 * Description: The place an import writes its notes, bases and attachments, given by the host: Graphite's vault
 *              writes in the app, the plugin runtime's vault in the WebAssembly build, a folder on disk
 *              (`FolderImportDestination`, in ImporterFileSystem) for tests and tools.
 *
 * Authors: Bahey Shalash
 * Version: 0.3
 * Date: 27/11/2026
 */

/// Where an import writes. The importer never opens files itself: the host decides how a write reaches the vault, so
/// that Graphite can coordinate it with iCloud and its index, and a WebAssembly build can pass it to the plugin
/// runtime.
public protocol ImportDestination: Sendable {
    /// Makes the folder at `path`, and the folders above it, when they do not exist yet.
    func createFolder(at path: VaultPath) async throws

    /// Writes `contents` as a new file at `path`. A file already there is never replaced: the write fails with
    /// `ImportDestinationError.fileAlreadyExists`.
    func writeNewFile(_ contents: [UInt8], at path: VaultPath) async throws

    /// A new, empty file at `path`, written piece by piece, for attachments too large to hold whole. A file already
    /// there is never replaced: the call fails with `ImportDestinationError.fileAlreadyExists`.
    func createNewFile(at path: VaultPath) async throws -> any ImportFileWriting

    /// The names of the files and folders inside the folder at `path`, empty when there is no folder there.
    func names(inFolderAt path: VaultPath) async throws -> [String]

    /// Gives each property of `types` its type in the vault's property types (Obsidian's `.obsidian/types.json`),
    /// keeping every type already assigned there. Returns the names of the properties that already had a different
    /// type, which keep it.
    func assignPropertyTypes(_ types: [String: PropertyType]) async throws -> [String]
}

/// A new file being written piece by piece.
public protocol ImportFileWriting: Sendable {
    /// Adds `bytes` at the end of the file.
    func append(_ bytes: [UInt8]) async throws

    /// Ends the file.
    func close() async throws
}

/// Why a destination refused a write.
public enum ImportDestinationError: Error, Equatable, Sendable {
    /// A file is already at the path written to.
    case fileAlreadyExists(VaultPath)
    /// The vault's property types file is not a JSON object of the form Obsidian writes, so it is left as it is.
    case unreadablePropertyTypes(VaultPath)
}
