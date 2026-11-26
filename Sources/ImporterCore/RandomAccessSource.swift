/**
 * File: RandomAccessSource.swift
 * ------------------------------
 * Layer: Core
 * Description: The export an import reads, given by the host as bytes read by range: a picked file, a part of
 *              another source, or bytes in memory.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

/// Bytes read by range, never all at once: a zip's central directory is read from its end, then each entry from its
/// own offset, so an export of several GB is never held in memory.
public protocol RandomAccessSource: Sendable {
    /// The number of bytes in the source.
    var size: UInt64 { get }

    /// The bytes from `offset`, `count` of them or fewer when the source ends first.
    func read(at offset: UInt64, count: Int) async throws -> Data
}

/// Why a source could not be read.
public enum RandomAccessSourceError: Error, Equatable, Sendable {
    /// A range was asked for past the end of the source.
    case rangeOutsideSource(offset: UInt64, count: Int, size: UInt64)
}

extension RandomAccessSource {
    /// Exactly `count` bytes from `offset`, or an error when the source ends first.
    public func readExactly(at offset: UInt64, count: Int) async throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        var bytes = Data()
        while bytes.count < count {
            let piece = try await read(at: offset + UInt64(bytes.count), count: count - bytes.count)
            if piece.isEmpty {
                throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
            }
            bytes.append(piece)
        }
        return bytes
    }
}

/// A source held in memory, for small exports, nested archives already inflated, and tests.
public struct DataRandomAccessSource: RandomAccessSource {
    /// The bytes of the source.
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var size: UInt64 {
        UInt64(data.count)
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        guard offset <= size else {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        let start = data.startIndex + Int(offset)
        let end = start + min(count, data.count - Int(offset))
        return Data(data[start..<end])
    }
}

/// A range of another source, such as a zip stored without compression inside a zip.
public struct SliceRandomAccessSource: RandomAccessSource {
    /// The source the slice is part of.
    public let base: any RandomAccessSource
    /// Where the slice starts in `base`.
    public let offset: UInt64
    public let size: UInt64

    /// The `size` bytes of `base` from `offset`, or `nil` when they do not fit in `base`.
    public init?(base: any RandomAccessSource, offset: UInt64, size: UInt64) {
        guard offset <= base.size, size <= base.size - offset else { return nil }
        self.base = base
        self.offset = offset
        self.size = size
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        guard offset <= size else {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        return try await base.read(at: self.offset + offset, count: Int(min(UInt64(count), size - offset)))
    }
}

/// A file on disk read by range, for tests and tools.
public actor FileRandomAccessSource: RandomAccessSource {
    public nonisolated let size: UInt64
    private let handle: FileHandle

    /// The file at `url`, opened for reading.
    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        self.size = try handle.seekToEnd()
        self.handle = handle
    }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset <= size else {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }
}
