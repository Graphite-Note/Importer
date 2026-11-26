/**
 * File: ImportDestination.swift
 * -----------------------------
 * Layer: Core
 * Description: The place an import writes its notes, bases and attachments, given by the host: Graphite's vault
 *              writes in the app, a folder on disk for tests and tools.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

/// Where an import writes. The importer never opens files itself: the host decides how a write reaches the vault, so
/// that Graphite can coordinate it with iCloud and its index, and a WebAssembly build can pass it to the plugin
/// runtime.
public protocol ImportDestination: Sendable {
    /// Makes the folder at `path`, and the folders above it, when they do not exist yet.
    func createFolder(at path: VaultPath) async throws

    /// Writes `contents` as a new file at `path`. A file already there is never replaced: the write fails with
    /// `ImportDestinationError.fileAlreadyExists`.
    func writeNewFile(_ contents: Data, at path: VaultPath) async throws

    /// The names of the files and folders inside the folder at `path`, empty when there is no folder there.
    func names(inFolderAt path: VaultPath) async throws -> [String]
}

/// Why a destination refused a write.
public enum ImportDestinationError: Error, Equatable, Sendable {
    /// A file is already at the path written to.
    case fileAlreadyExists(VaultPath)
}
