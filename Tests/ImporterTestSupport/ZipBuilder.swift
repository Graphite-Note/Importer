/**
 * File: ZipBuilder.swift
 * ----------------------
 * Layer: Tests
 * Description: Writes small zip archives for the tests: entries stored, or deflated from bytes compressed beforehand,
 *              with zip64 records on demand and with crafted names, so that each case the zip reader meets is made in
 *              the test instead of committed as a binary file.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation
import ImporterCore

/// A zip archive written in memory.
public struct ZipBuilder {
    /// One entry to write.
    public struct Entry {
        public var name: String
        /// The bytes the entry decodes to.
        public var contents: Data
        /// The bytes written for it: `contents` when stored, raw DEFLATE when deflated.
        public var storedBytes: Data
        public var compressionMethod: UInt16
        /// The Unix mode written in the external attributes, such as 0o120777 for a link.
        public var unixMode: UInt32

        /// An entry stored without compression.
        public static func stored(_ name: String, _ contents: Data, unixMode: UInt32 = 0o100644) -> Entry {
            Entry(name: name, contents: contents, storedBytes: contents, compressionMethod: 0, unixMode: unixMode)
        }

        /// An entry stored without compression, holding `text` in UTF-8.
        public static func stored(_ name: String, text: String) -> Entry {
            stored(name, Data(text.utf8))
        }

        /// An entry deflated: `deflated` is the raw DEFLATE of `contents`, compressed beforehand.
        public static func deflated(_ name: String, contents: Data, deflated: Data) -> Entry {
            Entry(name: name, contents: contents, storedBytes: deflated, compressionMethod: 8, unixMode: 0o100644)
        }
    }

    public var entries: [Entry]
    /// Whether to write zip64 records (the sizes and offsets in zip64 extra fields, and the zip64 end records).
    public var usesZip64: Bool

    public init(entries: [Entry], usesZip64: Bool = false) {
        self.entries = entries
        self.usesZip64 = usesZip64
    }

    /// The archive's bytes.
    public var data: Data {
        var archive = Data()
        var centralDirectory = Data()
        for entry in entries {
            let offset = UInt64(archive.count)
            let name = Data(entry.name.utf8)
            let checksum = CRC32.checksum(of: entry.contents)
            var zip64Extra = Data()
            if usesZip64 {
                zip64Extra.appendLittleEndian(UInt16(0x0001))
                zip64Extra.appendLittleEndian(UInt16(24))
                zip64Extra.appendLittleEndian(UInt64(entry.contents.count))
                zip64Extra.appendLittleEndian(UInt64(entry.storedBytes.count))
                zip64Extra.appendLittleEndian(offset)
            }
            let small32: (UInt64) -> UInt32 = { usesZip64 ? 0xFFFF_FFFF : UInt32($0) }
            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(usesZip64 ? 45 : 20))
            archive.appendLittleEndian(UInt16(1 << 11))
            archive.appendLittleEndian(entry.compressionMethod)
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(checksum)
            archive.appendLittleEndian(small32(UInt64(entry.storedBytes.count)))
            archive.appendLittleEndian(small32(UInt64(entry.contents.count)))
            archive.appendLittleEndian(UInt16(name.count))
            archive.appendLittleEndian(UInt16(zip64Extra.count))
            archive.append(name)
            archive.append(zip64Extra)
            archive.append(entry.storedBytes)

            centralDirectory.appendLittleEndian(UInt32(0x0201_4B50))
            centralDirectory.appendLittleEndian(UInt16(3 << 8 | 45))
            centralDirectory.appendLittleEndian(UInt16(usesZip64 ? 45 : 20))
            centralDirectory.appendLittleEndian(UInt16(1 << 11))
            centralDirectory.appendLittleEndian(entry.compressionMethod)
            centralDirectory.appendLittleEndian(UInt32(0))
            centralDirectory.appendLittleEndian(checksum)
            centralDirectory.appendLittleEndian(small32(UInt64(entry.storedBytes.count)))
            centralDirectory.appendLittleEndian(small32(UInt64(entry.contents.count)))
            centralDirectory.appendLittleEndian(UInt16(name.count))
            centralDirectory.appendLittleEndian(UInt16(zip64Extra.count))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(entry.unixMode << 16)
            centralDirectory.appendLittleEndian(small32(offset))
            centralDirectory.append(name)
            centralDirectory.append(zip64Extra)
        }
        let directoryOffset = UInt64(archive.count)
        archive.append(centralDirectory)
        if usesZip64 {
            let zip64RecordOffset = UInt64(archive.count)
            archive.appendLittleEndian(UInt32(0x0606_4B50))
            archive.appendLittleEndian(UInt64(44))
            archive.appendLittleEndian(UInt16(45))
            archive.appendLittleEndian(UInt16(45))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(UInt64(entries.count))
            archive.appendLittleEndian(UInt64(entries.count))
            archive.appendLittleEndian(UInt64(centralDirectory.count))
            archive.appendLittleEndian(directoryOffset)
            archive.appendLittleEndian(UInt32(0x0706_4B50))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(zip64RecordOffset)
            archive.appendLittleEndian(UInt32(1))
        }
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(usesZip64 ? 0xFFFF : UInt16(entries.count)))
        archive.appendLittleEndian(UInt16(usesZip64 ? 0xFFFF : UInt16(entries.count)))
        archive.appendLittleEndian(usesZip64 ? 0xFFFF_FFFF : UInt32(centralDirectory.count))
        archive.appendLittleEndian(usesZip64 ? 0xFFFF_FFFF : UInt32(directoryOffset))
        archive.appendLittleEndian(UInt16(0))
        return archive
    }
}

extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// The folder of the committed test material, `Tests/Fixtures`.
public let fixturesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
