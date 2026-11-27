/**
 * File: FileRandomAccessSource.swift
 * ----------------------------------
 * Layer: File system
 * Description: A file on disk read by range, the source of an import run by a host that reads files itself: the
 *              linked build, the `importer` command and the tests.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
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
        try handle.seek(toOffset: offset)
        return [UInt8](try handle.read(upToCount: count) ?? Data())
    }
}
