/**
 * File: FolderExportFileTree.swift
 * --------------------------------
 * Layer: File system
 * Description: The files of an export already unpacked into a folder on disk, each read piece by piece when its turn
 *              comes.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import Foundation
import ImporterCore

extension ExportFileTree {
    /// The files of the folder at `folder`, an export already unpacked. Links are skipped, so nothing outside the
    /// folder is read.
    public static func reading(folder: URL) throws -> ExportFileTree {
        var files: [ExportFile] = []
        var skipped: [SkippedExportEntry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return ExportFileTree(files: [], skippedEntries: [])
        }
        let basePath = folder.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            let fullPath = url.standardizedFileURL.path
            guard fullPath.hasPrefix(basePath) else { continue }
            let relative = fullPath.dropFirst(basePath.count).split(separator: "/").map(String.init)
            if isMacOSMetadata(relative) { continue }
            if values.isSymbolicLink == true {
                skipped.append(SkippedExportEntry(origin: relative.joined(separator: "/"), reason: "it is a link"))
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = UInt64(values.fileSize ?? 0)
            files.append(ExportFile(pathComponents: relative, size: size, origin: relative.joined(separator: "/")) {
                try FolderFileReader(url: url)
            })
        }
        files.sort { $0.path < $1.path }
        return ExportFileTree(files: files, skippedEntries: skipped)
    }
}

/// A file on disk read piece by piece.
struct FolderFileReader: ExportFileReading {
    private let handle: FileHandle
    private var isDone = false

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    mutating func read() async throws -> [UInt8]? {
        guard !isDone else { return nil }
        let piece = try handle.read(upToCount: ZipEntryReader.pieceSize) ?? Data()
        if piece.isEmpty {
            isDone = true
            try handle.close()
            return nil
        }
        return [UInt8](piece)
    }
}
