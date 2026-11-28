/**
 * File: FileRandomAccessSource.swift
 * ----------------------------------
 * Layer: File system
 * Description: A file on disk read by range, the source of an import run by a host that reads files itself: the
 *              linked build, the `importer` command and the tests.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 28/11/2026
 */

import Foundation
import ImporterCore

/// A file on disk read by range.
public actor FileRandomAccessSource: RandomAccessSource {
    public nonisolated let size: UInt64
    private let handle: FileHandle

    /// The file at `url`, opened for reading.
    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        self.size = try handle.seekToEnd()
        self.handle = handle
    }

    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard offset <= size else {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        #if os(WASI)
        try handle.seek(toOffset: offset)
        return [UInt8](try handle.read(upToCount: count) ?? Data())
        #else
        // Read through the descriptor: the handle's reads leave their buffers to an autorelease pool, which an
        // import's tasks never drain, so 33 GB read stayed 33 GB held.
        return try FileDescriptorIO.read(handle.fileDescriptor, at: offset, count: Int(min(UInt64(count), size - offset)))
        #endif
    }
}
