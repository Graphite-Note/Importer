/**
 * File: TemporaryStorage.swift
 * ----------------------------
 * Layer: Core
 * Description: Room for bytes an import needs to read again by range while it runs, such as a compressed zip found
 *              inside the export, given by the host: memory, or a folder of temporary files.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

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
    func append(_ bytes: Data) async throws

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
    private var bytes = Data()

    func append(_ bytes: Data) {
        self.bytes.append(bytes)
    }

    func finish() -> any RandomAccessSource {
        DataRandomAccessSource(bytes)
    }
}

/// Temporary files in a folder on disk, which this storage makes and removes.
public actor FolderTemporaryStorage: TemporaryStorage {
    /// The folder the files are written in.
    public nonisolated let folder: URL
    private var madeFiles: [URL] = []

    /// Files in `folder`, which is made when it does not exist yet.
    public init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
    }

    public func makeFile() throws -> any TemporaryFileWriting {
        let url = folder.appendingPathComponent("importer-\(UUID().uuidString).tmp")
        try Data().write(to: url, options: .withoutOverwriting)
        madeFiles.append(url)
        return try FolderTemporaryFile(url: url)
    }

    public func removeAll() {
        for url in madeFiles {
            try? FileManager.default.removeItem(at: url)
        }
        madeFiles = []
    }
}

actor FolderTemporaryFile: TemporaryFileWriting {
    private let url: URL
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        self.handle = try FileHandle(forWritingTo: url)
    }

    func append(_ bytes: Data) throws {
        try handle.write(contentsOf: bytes)
    }

    func finish() throws -> any RandomAccessSource {
        try handle.close()
        return try FileRandomAccessSource(url: url)
    }
}
