/**
 * File: TemporaryStorage.swift
 * ----------------------------
 * Layer: Core
 * Description: Room for bytes an import needs to read again by range while it runs, such as a compressed zip found
 *              inside the export, given by the host: memory, or a folder of temporary files
 *              (`FolderTemporaryStorage`, in ImporterFileSystem).
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

/// Where an import keeps bytes it must read again by range: a zip inside the export that was compressed has to be
/// inflated before its central directory can be read.
public protocol TemporaryStorage: Sendable {
    /// A new temporary file, empty.
    func makeFile() async throws -> any TemporaryFileWriting

    /// Removes every temporary file made, once the import no longer reads them.
    func removeAll() async
}

/// A temporary file being written.
public protocol TemporaryFileWriting: Sendable {
    /// Adds `bytes` at the end of the file.
    func append(_ bytes: [UInt8]) async throws

    /// Ends writing and returns the file's bytes as a source.
    func finish() async throws -> any RandomAccessSource
}

/// Temporary files held in memory, for small exports, tests, and hosts without a place on disk.
public struct MemoryTemporaryStorage: TemporaryStorage {
    public init() {}

    public func makeFile() async throws -> any TemporaryFileWriting {
        MemoryTemporaryFile()
    }

    public func removeAll() async {}
}

actor MemoryTemporaryFile: TemporaryFileWriting {
    private var bytes: [UInt8] = []

    func append(_ bytes: [UInt8]) {
        self.bytes.append(contentsOf: bytes)
    }

    func finish() -> any RandomAccessSource {
        MemoryRandomAccessSource(bytes)
    }
}
