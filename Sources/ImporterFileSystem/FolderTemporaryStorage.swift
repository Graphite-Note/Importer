/**
 * File: FolderTemporaryStorage.swift
 * ----------------------------------
 * Layer: File system
 * Description: Temporary files in a folder on disk, for the bytes an import reads again by range, such as a
 *              compressed zip found inside the export.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import Foundation
import ImporterCore

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

    func append(_ bytes: [UInt8]) throws {
        try handle.write(contentsOf: bytes)
    }

    func finish() throws -> any RandomAccessSource {
        try handle.close()
        return try FileRandomAccessSource(url: url)
    }
}
