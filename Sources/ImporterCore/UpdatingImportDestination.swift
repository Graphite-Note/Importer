/**
 * File: UpdatingImportDestination.swift
 * -------------------------------------
 * Layer: Core
 * Description: A destination an import can update: the files of an earlier import read back, and replaced only while
 *              they still hold what was read, with the fingerprint that tells whether a file is still what an import
 *              wrote.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

/// A destination an import of the same workspace can update.
///
/// An import that updates an earlier one replaces only the files that import wrote and nobody changed since, so a
/// replacement says what it expects to replace: the host refuses it when the file changed in between, as an edit
/// made while the import runs.
public protocol UpdatingImportDestination: ImportDestination {
    /// The bytes of the file at `path`, `nil` when there is none.
    func readFile(at path: VaultPath) async throws -> [UInt8]?

    /// Replaces the file at `path`, which must still hold `expected`, with `contents`. Fails with
    /// `ImportUpdateError.changedSinceRead` when the file holds anything else or is gone.
    func replaceFile(at path: VaultPath, expecting expected: [UInt8], with contents: [UInt8]) async throws

    /// The path of every file inside the folder at `path` and its subfolders, empty when there is no folder there.
    func filePaths(inFolderAt path: VaultPath) async throws -> [VaultPath]
}

/// Why a destination refused to replace a file.
public enum ImportUpdateError: Error, Equatable, Sendable {
    /// The file no longer holds what was read before replacing it.
    case changedSinceRead(VaultPath)
}

/// A short fingerprint of a file's bytes, 64-bit FNV-1a as 16 lowercase hexadecimal digits: enough to tell whether a
/// file is still what an import wrote, not a guard against anyone forging one.
public enum ContentFingerprint {
    public static func of(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
        var text = ""
        for shift in stride(from: 60, through: 0, by: -4) { text.append(digits[Int((hash >> UInt64(shift)) & 0xF)]) }
        return text
    }
}
