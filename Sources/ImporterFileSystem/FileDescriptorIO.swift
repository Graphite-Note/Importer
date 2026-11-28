/**
 * File: FileDescriptorIO.swift
 * ----------------------------
 * Layer: File system
 * Description: Reads and writes of an open file through its descriptor, into and from byte arrays, so that an import
 *              of gigabytes leaves no buffers behind: Foundation's file handles answer with objects that Apple's
 *              systems release only when an autorelease pool drains, which an import's tasks never do.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 28/11/2026
 */

#if !os(WASI)
import Foundation

/// The reads and writes of a file descriptor the caller owns.
enum FileDescriptorIO {
    /// Up to `count` bytes at `offset`, fewer at the file's end.
    static func read(_ descriptor: Int32, at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let read = bytes.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            }
            if read < 0 {
                if errno == EINTR { continue }
                throw FileDescriptorIOError.failed("pread", errno)
            }
            if read == 0 { break }
            done += read
        }
        if done < count { bytes.removeLast(count - done) }
        return bytes
    }

    /// Writes all of `bytes` at the descriptor's position.
    static func write(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        var done = 0
        while done < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Foundation.write(descriptor, buffer.baseAddress! + done, bytes.count - done)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw FileDescriptorIOError.failed("write", errno)
            }
            done += written
        }
    }
}

/// A read or write the system refused.
public enum FileDescriptorIOError: Error, Equatable, CustomStringConvertible {
    case failed(String, Int32)

    public var description: String {
        switch self {
        case .failed(let call, let code): return "\(call) failed with error \(code)"
        }
    }
}
#endif
