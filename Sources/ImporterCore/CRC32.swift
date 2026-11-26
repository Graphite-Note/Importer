/**
 * File: CRC32.swift
 * -----------------
 * Layer: Core
 * Description: The CRC-32 checksum zip archives keep for each entry, computed as an entry is read, so that a damaged
 *              or truncated export is refused instead of imported wrong.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

/// The CRC-32 of ISO 3309 and zip (polynomial 0xEDB88320, reflected), computed over bytes given piece by piece.
public struct CRC32: Sendable {
    /// The checksum of the bytes given so far.
    public private(set) var value: UInt32 = 0

    public init() {}

    /// Adds `bytes` to the checksum.
    public mutating func update(with bytes: some Sequence<UInt8>) {
        var remainder = ~value
        for byte in bytes {
            remainder = CRC32.table[Int((remainder ^ UInt32(byte)) & 0xFF)] ^ (remainder >> 8)
        }
        value = ~remainder
    }

    /// The checksum of `bytes`.
    public static func checksum(of bytes: some Sequence<UInt8>) -> UInt32 {
        var crc = CRC32()
        crc.update(with: bytes)
        return crc.value
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var remainder = UInt32(index)
        for _ in 0..<8 {
            remainder = remainder & 1 == 1 ? 0xEDB8_8320 ^ (remainder >> 1) : remainder >> 1
        }
        return remainder
    }
}
