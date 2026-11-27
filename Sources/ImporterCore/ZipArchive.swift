/**
 * File: ZipArchive.swift
 * ----------------------
 * Layer: Core
 * Description: Reads a zip archive from a random-access source: the central directory first, then each entry on its
 *              own, stored or deflated, checked against its CRC-32, with zip64 for archives and entries over 4 GB.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

/// Why a zip archive or one of its entries could not be read.
public enum ZipArchiveError: Error, Equatable, Sendable {
    /// No end of central directory record: the file is not a zip, or it was cut short.
    case notAZipArchive
    /// The central directory, or an entry's local header, is not where the archive says, or is damaged.
    case damagedArchive(String)
    /// The entry is encrypted.
    case encryptedEntry(String)
    /// The entry is compressed with a method other than stored (0) and deflated (8).
    case unsupportedCompressionMethod(entry: String, method: UInt16)
    /// The entry decoded to bytes whose size or CRC-32 differs from the archive's record.
    case checksumMismatch(String)
    /// The entry is larger than the most a caller asked to hold in memory.
    case entryTooLarge(entry: String, size: UInt64)
}

/// A zip archive read from a source.
public struct ZipArchive: Sendable {
    /// One file or folder of the archive, as its central directory records it.
    public struct Entry: Sendable, Equatable {
        /// The entry's path in the archive, with "/" between names, as the archive spells it.
        public let path: String
        /// The names of `path`, without empty names.
        public var pathComponents: [String] {
            path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        /// The bytes the entry takes in the archive.
        public let compressedSize: UInt64
        /// The bytes the entry holds once decoded.
        public let uncompressedSize: UInt64
        /// The compression method: 0 stored, 8 deflated.
        public let compressionMethod: UInt16
        /// The CRC-32 of the decoded bytes.
        public let checksum: UInt32
        /// Where the entry's local header starts in the archive.
        public let localHeaderOffset: UInt64
        /// Whether the entry is a folder.
        public let isFolder: Bool
        /// Whether the entry is a symbolic link (a Unix mode in its external attributes).
        public let isSymbolicLink: Bool
        /// Whether the entry is encrypted.
        public let isEncrypted: Bool

        /// Whether the path could reach outside the folder the archive is read into: an absolute path, a drive
        /// letter, a ".." name or a backslash, or a link. Such entries are reported, never read.
        public var isUnsafe: Bool {
            isSymbolicLink || path.hasPrefix("/") || path.contains("\\") || path.unicodeScalars.contains("\u{0}")
                || pathComponents.contains("..") || (pathComponents.first.map { $0.count == 2 && $0.hasSuffix(":") } ?? false)
        }
    }

    /// The archive's entries, in the order of its central directory.
    public let entries: [Entry]
    /// The source the archive is read from.
    public let source: any RandomAccessSource

    private init(entries: [Entry], source: any RandomAccessSource) {
        self.entries = entries
        self.source = source
    }

    // MARK: Opening

    /// The archive in `source`, its central directory read.
    public static func open(_ source: any RandomAccessSource) async throws -> ZipArchive {
        let directory = try await findCentralDirectory(in: source)
        guard directory.offset <= source.size, directory.size <= source.size - directory.offset,
            directory.size <= UInt64(Int.max)
        else {
            throw ZipArchiveError.damagedArchive("the central directory lies outside the archive")
        }
        let bytes = ByteReader(try await readExactly(from: source, at: directory.offset, count: Int(directory.size)))
        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(directory.entryCount, 1_000_000)))
        while entries.count < directory.entryCount {
            entries.append(try readCentralDirectoryEntry(from: bytes))
        }
        return ZipArchive(entries: entries, source: source)
    }

    private struct CentralDirectoryLocation {
        var entryCount: UInt64
        var size: UInt64
        var offset: UInt64
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    private static func findCentralDirectory(in source: any RandomAccessSource) async throws -> CentralDirectoryLocation {
        // The end record is 22 bytes plus a comment of at most 65,535 bytes, at the very end.
        let tailCount = Int(min(source.size, 22 + 65_535))
        guard tailCount >= 22 else { throw ZipArchiveError.notAZipArchive }
        let tailStart = source.size - UInt64(tailCount)
        let tail = ByteReader(try await readExactly(from: source, at: tailStart, count: tailCount))
        var recordStart: Int?
        var position = tailCount - 22
        while position >= 0 {
            if tail.uint32(at: position) == endOfCentralDirectorySignature,
                position + 22 + Int(tail.uint16(at: position + 20)) <= tailCount
            {
                recordStart = position
                break
            }
            position -= 1
        }
        guard let recordStart else { throw ZipArchiveError.notAZipArchive }
        var location = CentralDirectoryLocation(entryCount: UInt64(tail.uint16(at: recordStart + 10)),
                                                size: UInt64(tail.uint32(at: recordStart + 12)),
                                                offset: UInt64(tail.uint32(at: recordStart + 16)))
        // A zip64 archive keeps a locator just before the end record, pointing at the zip64 end record.
        let locatorStart = recordStart - 20
        if locatorStart >= 0, tail.uint32(at: locatorStart) == zip64LocatorSignature {
            let zip64RecordOffset = tail.uint64(at: locatorStart + 8)
            guard zip64RecordOffset <= source.size, source.size - zip64RecordOffset >= 56 else {
                throw ZipArchiveError.damagedArchive("the zip64 end record lies outside the archive")
            }
            let record = ByteReader(try await readExactly(from: source, at: zip64RecordOffset, count: 56))
            guard record.uint32(at: 0) == zip64EndOfCentralDirectorySignature else {
                throw ZipArchiveError.damagedArchive("the zip64 end record is missing")
            }
            location = CentralDirectoryLocation(entryCount: record.uint64(at: 32), size: record.uint64(at: 40),
                                                offset: record.uint64(at: 48))
        }
        return location
    }

    private static func readCentralDirectoryEntry(from bytes: ByteReader) throws -> Entry {
        guard bytes.remainingCount >= 46, bytes.uint32(at: bytes.position) == centralDirectorySignature else {
            throw ZipArchiveError.damagedArchive("a central directory entry is damaged")
        }
        let start = bytes.position
        let versionMadeBy = bytes.uint16(at: start + 4)
        let flags = bytes.uint16(at: start + 8)
        let method = bytes.uint16(at: start + 10)
        let checksum = bytes.uint32(at: start + 16)
        var compressedSize = UInt64(bytes.uint32(at: start + 20))
        var uncompressedSize = UInt64(bytes.uint32(at: start + 24))
        let nameLength = Int(bytes.uint16(at: start + 28))
        let extraLength = Int(bytes.uint16(at: start + 30))
        let commentLength = Int(bytes.uint16(at: start + 32))
        let externalAttributes = bytes.uint32(at: start + 38)
        var localHeaderOffset = UInt64(bytes.uint32(at: start + 42))
        guard bytes.remainingCount >= 46 + nameLength + extraLength + commentLength else {
            throw ZipArchiveError.damagedArchive("a central directory entry is cut short")
        }
        let rawName = bytes.slice(at: start + 46, count: nameLength)
        let extra = ByteReader(bytes.slice(at: start + 46 + nameLength, count: extraLength))
        var unicodePath: String?
        // Extra fields: zip64 sizes and offset (0x0001), Info-ZIP's Unicode path (0x7075).
        while extra.remainingCount >= 4 {
            let identifier = extra.uint16(at: extra.position)
            let fieldLength = Int(extra.uint16(at: extra.position + 2))
            let fieldStart = extra.position + 4
            guard extra.remainingCount >= 4 + fieldLength else { break }
            if identifier == 0x0001 {
                var cursor = fieldStart
                let fieldEnd = fieldStart + fieldLength
                if uncompressedSize == 0xFFFF_FFFF, cursor + 8 <= fieldEnd {
                    uncompressedSize = extra.uint64(at: cursor)
                    cursor += 8
                }
                if compressedSize == 0xFFFF_FFFF, cursor + 8 <= fieldEnd {
                    compressedSize = extra.uint64(at: cursor)
                    cursor += 8
                }
                if localHeaderOffset == 0xFFFF_FFFF, cursor + 8 <= fieldEnd {
                    localHeaderOffset = extra.uint64(at: cursor)
                }
            } else if identifier == 0x7075, fieldLength > 5 {
                unicodePath = String(validating: extra.slice(at: fieldStart + 5, count: fieldLength - 5), as: UTF8.self)
            }
            extra.position = fieldStart + fieldLength
        }
        bytes.position = start + 46 + nameLength + extraLength + commentLength
        let isUTF8 = flags & (1 << 11) != 0
        let path = unicodePath ?? ZipArchive.decodeName(rawName, isUTF8: isUTF8)
        let madeOnUnix = versionMadeBy >> 8 == 3
        let unixMode = externalAttributes >> 16
        return Entry(path: path, compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                     compressionMethod: method, checksum: checksum, localHeaderOffset: localHeaderOffset,
                     isFolder: path.hasSuffix("/"), isSymbolicLink: madeOnUnix && unixMode & 0o170000 == 0o120000,
                     isEncrypted: flags & 1 != 0)
    }

    /// A name as UTF-8 when it reads as UTF-8 (many archivers write UTF-8 without setting its flag), else as code
    /// page 437, the encoding zip names have without the flag.
    static func decodeName(_ bytes: [UInt8], isUTF8: Bool) -> String {
        if let name = String(validating: bytes, as: UTF8.self) { return name }
        if isUTF8 { return String(decoding: bytes, as: UTF8.self) }
        return String(String.UnicodeScalarView(bytes.map { byte in
            byte < 0x80 ? Unicode.Scalar(byte) : ZipArchive.codePage437[Int(byte - 0x80)]
        }))
    }

    private static let codePage437: [Unicode.Scalar] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{A0}"
            .unicodeScalars)

    // MARK: Reading entries

    /// A reader of `entry`'s decoded bytes, piece by piece.
    public func reader(for entry: Entry) async throws -> ZipEntryReader {
        guard !entry.isEncrypted else { throw ZipArchiveError.encryptedEntry(entry.path) }
        guard entry.compressionMethod == 0 || entry.compressionMethod == 8 else {
            throw ZipArchiveError.unsupportedCompressionMethod(entry: entry.path, method: entry.compressionMethod)
        }
        guard entry.localHeaderOffset <= source.size, source.size - entry.localHeaderOffset >= 30 else {
            throw ZipArchiveError.damagedArchive("the local header of \(entry.path) lies outside the archive")
        }
        let header = ByteReader(try await readExactly(from: source, at: entry.localHeaderOffset, count: 30))
        guard header.uint32(at: 0) == ZipArchive.localHeaderSignature else {
            throw ZipArchiveError.damagedArchive("the local header of \(entry.path) is missing")
        }
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
        guard dataOffset <= source.size, entry.compressedSize <= source.size - dataOffset else {
            throw ZipArchiveError.damagedArchive("\(entry.path) is cut short")
        }
        return ZipEntryReader(entry: entry, source: source, dataOffset: dataOffset)
    }

    /// All of `entry`'s decoded bytes, refused when it holds more than `maximumSize` bytes.
    public func contents(of entry: Entry, maximumSize: UInt64 = 256 * 1024 * 1024) async throws -> [UInt8] {
        guard entry.uncompressedSize <= maximumSize else {
            throw ZipArchiveError.entryTooLarge(entry: entry.path, size: entry.uncompressedSize)
        }
        var reader = try await reader(for: entry)
        var contents: [UInt8] = []
        contents.reserveCapacity(Int(entry.uncompressedSize))
        while let piece = try await reader.read() {
            contents.append(contentsOf: piece)
        }
        return contents
    }
}

/// The decoded bytes of one zip entry, read piece by piece, checked against the entry's size and CRC-32 once the last
/// piece is read.
public struct ZipEntryReader: Sendable {
    /// The entry read.
    public let entry: ZipArchive.Entry
    private let source: any RandomAccessSource
    private let dataOffset: UInt64
    private var compressedBytesRead: UInt64 = 0
    private var decodedByteCount: UInt64 = 0
    private var checksum = CRC32()
    private var inflater = Inflater()
    private var isDone = false

    /// The size of the compressed pieces read from the source.
    public static let pieceSize = 65_536

    init(entry: ZipArchive.Entry, source: any RandomAccessSource, dataOffset: UInt64) {
        self.entry = entry
        self.source = source
        self.dataOffset = dataOffset
    }

    /// The next decoded piece, `nil` once the entry is read whole and checked.
    public mutating func read() async throws -> [UInt8]? {
        guard !isDone else { return nil }
        while true {
            let piece: [UInt8]
            if entry.compressionMethod == 0 {
                piece = try await readCompressed()
            } else {
                var output = try inflater.inflate(isInputComplete: compressedBytesRead == entry.compressedSize)
                while output.isEmpty, !inflater.isFinished {
                    let compressed = try await readCompressed()
                    if compressed.isEmpty {
                        output = try inflater.inflate(isInputComplete: true)
                        break
                    }
                    inflater.append(compressed)
                    output = try inflater.inflate(isInputComplete: compressedBytesRead == entry.compressedSize)
                }
                piece = output
            }
            if !piece.isEmpty {
                checksum.update(with: piece)
                decodedByteCount += UInt64(piece.count)
                guard decodedByteCount <= entry.uncompressedSize else {
                    throw ZipArchiveError.checksumMismatch(entry.path)
                }
                return piece
            }
            let isComplete = entry.compressionMethod == 0 ? compressedBytesRead == entry.compressedSize : inflater.isFinished
            guard isComplete, decodedByteCount == entry.uncompressedSize, checksum.value == entry.checksum else {
                throw ZipArchiveError.checksumMismatch(entry.path)
            }
            isDone = true
            return nil
        }
    }

    private mutating func readCompressed() async throws -> [UInt8] {
        let count = Int(min(UInt64(ZipEntryReader.pieceSize), entry.compressedSize - compressedBytesRead))
        guard count > 0 else { return [] }
        let bytes = try await readExactly(from: source, at: dataOffset + compressedBytesRead, count: count)
        compressedBytesRead += UInt64(bytes.count)
        return bytes
    }
}

/// Little-endian integers read from bytes, with a cursor.
final class ByteReader {
    private let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remainingCount: Int {
        bytes.count - position
    }

    func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    func uint64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        return UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }

    func slice(at offset: Int, count: Int) -> [UInt8] {
        guard offset >= 0, count >= 0, offset + count <= bytes.count else { return [] }
        return Array(bytes[offset..<(offset + count)])
    }
}
