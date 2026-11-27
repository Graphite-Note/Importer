/**
 * File: ExportFileTree.swift
 * --------------------------
 * Layer: Core
 * Description: The files of an export, whatever holds them: one or more zip archives (with the zips nested inside
 *              them read the same way) or a folder the export was unpacked into (read by ImporterFileSystem). Each
 *              file is read piece by piece when its turn comes.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

/// A reader of one export file's bytes, piece by piece.
public protocol ExportFileReading {
    /// The next piece, `nil` once the file is read whole.
    mutating func read() async throws -> [UInt8]?
}

extension ZipEntryReader: ExportFileReading {}

/// One file of an export.
public struct ExportFile: Sendable {
    /// The file's path inside the export, one name per folder.
    public let pathComponents: [String]
    /// The file's size in bytes.
    public let size: UInt64
    /// Where the file came from, for messages: the archive and the path in it.
    public let origin: String
    private let opener: @Sendable () async throws -> any ExportFileReading

    public init(pathComponents: [String], size: UInt64, origin: String,
                opener: @escaping @Sendable () async throws -> any ExportFileReading) {
        self.pathComponents = pathComponents
        self.size = size
        self.origin = origin
        self.opener = opener
    }

    /// The file's name, the last of its path.
    public var name: String {
        pathComponents.last ?? ""
    }

    /// The file's path with "/" between its names.
    public var path: String {
        pathComponents.joined(separator: "/")
    }

    /// The same file at another path, such as its path without the folder an export wraps everything in.
    public func relocated(to pathComponents: [String]) -> ExportFile {
        ExportFile(pathComponents: pathComponents, size: size, origin: origin, opener: opener)
    }

    /// A reader of the file's bytes.
    public func openReader() async throws -> any ExportFileReading {
        try await opener()
    }

    /// All of the file's bytes, refused when it is larger than `maximumSize`.
    public func contents(maximumSize: UInt64 = 256 * 1024 * 1024) async throws -> [UInt8] {
        guard size <= maximumSize else { throw ZipArchiveError.entryTooLarge(entry: origin, size: size) }
        var reader = try await openReader()
        var contents: [UInt8] = []
        contents.reserveCapacity(Int(size))
        while let piece = try await reader.read() {
            contents.append(contentsOf: piece)
        }
        return contents
    }
}

/// An entry of an export that is not read, and why.
public struct SkippedExportEntry: Sendable, Equatable {
    /// The entry, named by its archive and its path there.
    public let origin: String
    /// Why it is not read.
    public let reason: String

    public init(origin: String, reason: String) {
        self.origin = origin
        self.reason = reason
    }
}

/// The files of an export.
public struct ExportFileTree: Sendable {
    /// The files, in the order their archives list them.
    public let files: [ExportFile]
    /// Entries left out: links and paths that could reach outside the export, encrypted entries, nested zips that
    /// could not be read.
    public let skippedEntries: [SkippedExportEntry]

    public init(files: [ExportFile], skippedEntries: [SkippedExportEntry]) {
        self.files = files
        self.skippedEntries = skippedEntries
    }

    /// The files of the zip archives `sources`, named `sourceNames` in messages. A zip inside one of them is read as
    /// part of the export, its files placed at the path of the zip's folder: Notion's large exports are a zip of
    /// `Part-N` zips. A nested zip stored without compression is read where it lies, a compressed one is first
    /// inflated into `temporaryStorage`.
    public static func reading(zipArchives sources: [any RandomAccessSource], named sourceNames: [String],
                               temporaryStorage: any TemporaryStorage, nestingDepthLimit: Int = 2) async throws -> ExportFileTree {
        var files: [ExportFile] = []
        var skipped: [SkippedExportEntry] = []
        for (index, source) in sources.enumerated() {
            let name = index < sourceNames.count ? sourceNames[index] : "export \(index + 1).zip"
            let archive = try await ZipArchive.open(source)
            try await collect(archive, named: name, under: [], depth: 0, depthLimit: nestingDepthLimit,
                              temporaryStorage: temporaryStorage, files: &files, skipped: &skipped)
        }
        return ExportFileTree(files: files, skippedEntries: skipped)
    }

    private static func collect(_ archive: ZipArchive, named archiveName: String, under folder: [String], depth: Int,
                                depthLimit: Int, temporaryStorage: any TemporaryStorage, files: inout [ExportFile],
                                skipped: inout [SkippedExportEntry]) async throws {
        for entry in archive.entries where !entry.isFolder {
            let origin = "\(archiveName)/\(entry.path)"
            let components = entry.pathComponents
            if isMacOSMetadata(components) { continue }
            if entry.isUnsafe {
                skipped.append(SkippedExportEntry(origin: origin, reason: "its path or link could reach outside the export"))
                continue
            }
            if entry.isEncrypted {
                skipped.append(SkippedExportEntry(origin: origin, reason: "it is encrypted"))
                continue
            }
            if components.last?.lowercased().hasSuffix(".zip") == true, depth < depthLimit {
                do {
                    let nestedSource = try await nestedArchiveSource(of: entry, in: archive, temporaryStorage: temporaryStorage)
                    let nested = try await ZipArchive.open(nestedSource)
                    try await collect(nested, named: origin, under: folder + components.dropLast(), depth: depth + 1,
                                      depthLimit: depthLimit, temporaryStorage: temporaryStorage, files: &files,
                                      skipped: &skipped)
                    continue
                } catch ZipArchiveError.notAZipArchive {
                    // A file named .zip that is not a zip is an attachment like any other.
                }
            }
            files.append(ExportFile(pathComponents: folder + components, size: entry.uncompressedSize, origin: origin) {
                try await archive.reader(for: entry)
            })
        }
    }

    private static func nestedArchiveSource(of entry: ZipArchive.Entry, in archive: ZipArchive,
                                            temporaryStorage: any TemporaryStorage) async throws -> any RandomAccessSource {
        let reader = try await archive.reader(for: entry)
        if entry.compressionMethod == 0 {
            // Stored: the nested zip's bytes lie as they are in the outer one. Its CRC-32 is checked by the reads of
            // its own entries, which have checksums of their own.
            let header = try await readExactly(from: archive.source, at: entry.localHeaderOffset, count: 30)
            let nameLength = UInt64(header[header.startIndex + 26]) | UInt64(header[header.startIndex + 27]) << 8
            let extraLength = UInt64(header[header.startIndex + 28]) | UInt64(header[header.startIndex + 29]) << 8
            let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
            if let slice = SliceRandomAccessSource(base: archive.source, offset: dataOffset, size: entry.compressedSize) {
                return slice
            }
            throw ZipArchiveError.damagedArchive("\(entry.path) is cut short")
        }
        var pieces = reader
        let file = try await temporaryStorage.makeFile()
        while let piece = try await pieces.read() {
            try await file.append(piece)
        }
        return try await file.finish()
    }

    /// The Finder's own files, which archivers on macOS add and which are no part of an export.
    public static func isMacOSMetadata(_ components: [String]) -> Bool {
        components.first == "__MACOSX" || components.last == ".DS_Store" || components.last?.hasPrefix("._") == true
    }
}

