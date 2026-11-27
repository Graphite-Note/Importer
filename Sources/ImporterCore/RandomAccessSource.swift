/**
 * File: RandomAccessSource.swift
 * ------------------------------
 * Layer: Core
 * Description: The export an import reads, given by the host as bytes read by range: a picked file, a part of
 *              another source, or bytes in memory. A file on disk is `FileRandomAccessSource`, in ImporterFileSystem.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

/// Bytes read by range, never all at once: a zip's central directory is read from its end, then each entry from its
/// own offset, so an export of several GB is never held in memory.
public protocol RandomAccessSource: Sendable {
    /// The number of bytes in the source.
    var size: UInt64 { get }

    /// The bytes from `offset`, `count` of them or fewer when the source ends first.
    func read(at offset: UInt64, count: Int) async throws -> [UInt8]
}

/// Why a source could not be read.
public enum RandomAccessSourceError: Error, Equatable, Sendable {
    /// A range was asked for past the end of the source.
    case rangeOutsideSource(offset: UInt64, count: Int, size: UInt64)
}

extension RandomAccessSource {
    /// Exactly `count` bytes from `offset`, or an error when the source ends first.
    public func readExactly(at offset: UInt64, count: Int) async throws -> [UInt8] {
        try await ImporterCore.readExactly(from: self, at: offset, count: count)
    }
}

/// Exactly `count` bytes of `source` from `offset`, or an error when the source ends first. A function of its own, not
/// only a method of the protocol's extension, because Embedded Swift cannot call such a method on `any
/// RandomAccessSource`.
package func readExactly(from source: any RandomAccessSource, at offset: UInt64, count: Int) async throws -> [UInt8] {
    let size = source.size
    guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
        throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    while bytes.count < count {
        let piece = try await source.read(at: offset + UInt64(bytes.count), count: count - bytes.count)
        if piece.isEmpty {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        bytes.append(contentsOf: piece)
    }
    return bytes
}

/// A source held in memory, for small exports, nested archives already inflated, and tests.
public struct MemoryRandomAccessSource: RandomAccessSource {
    /// The bytes of the source.
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var size: UInt64 {
        UInt64(bytes.count)
    }

    public func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
        guard offset <= size else {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        let start = Int(offset)
        let end = start + min(max(count, 0), bytes.count - start)
        return Array(bytes[start..<end])
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

    public func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
        guard offset <= size else {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        return try await base.read(at: self.offset + offset, count: Int(min(UInt64(count), size - offset)))
    }
}
