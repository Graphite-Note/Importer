/**
 * File: HostImport.swift
 * ----------------------
 * Layer: Plugin
 * Description: The source, destination and temporary storage of an import run in the plugin, each answered by the
 *              JavaScript host: the picked files read by range, the vault written through the plugin API, and
 *              temporary files kept by the host as blobs.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

#if os(WASI)
import ImporterCore

/// A file the host holds, read by range: a picked export, or a temporary file the host finished.
struct HostSource: RandomAccessSource {
    /// The host's number for the file.
    let index: Int
    let size: UInt64

    func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
        guard offset <= size else {
            throw RandomAccessSourceError.rangeOutsideSource(offset: offset, count: count, size: size)
        }
        let answer = try await callHostChecked(.read, [String(index), String(offset), String(count)])
        return answer.bytes
    }
}

/// The vault, written through the plugin API by the host. The host refuses to replace a file, as the protocol asks.
struct HostDestination: ImportDestination {
    func createFolder(at path: VaultPath) async throws {
        _ = try await callHostChecked(.createFolder, [path.description])
    }

    func writeNewFile(_ contents: [UInt8], at path: VaultPath) async throws {
        _ = try await callHostChecked(.writeNewFile, [path.description], contents, path: path)
    }

    func createNewFile(at path: VaultPath) async throws -> any ImportFileWriting {
        let answer = try await callHostChecked(.createNewFile, [path.description], path: path)
        return HostFileWriter(handle: answer.text)
    }

    func names(inFolderAt path: VaultPath) async throws -> [String] {
        try await callHostChecked(.names, [path.description]).texts
    }

    func assignPropertyTypes(_ types: [String: PropertyType]) async throws -> [String] {
        var arguments: [String] = []
        for (name, type) in types.sorted(by: { $0.key < $1.key }) {
            arguments.append(name)
            arguments.append(type.rawValue)
        }
        return try await callHostChecked(.assignPropertyTypes, arguments).texts
    }
}

/// A new vault file the host writes once it is closed.
struct HostFileWriter: ImportFileWriting {
    /// The host's number for the file.
    let handle: String

    func append(_ bytes: [UInt8]) async throws {
        _ = try await callHostChecked(.appendToFile, [handle], bytes)
    }

    func close() async throws {
        _ = try await callHostChecked(.closeFile, [handle])
    }
}

/// Temporary files kept by the host (blobs in the web view, which WebKit may keep on disk), so that a compressed
/// part of a large export is not held in the module's memory.
struct HostTemporaryStorage: TemporaryStorage {
    func makeFile() async throws -> any TemporaryFileWriting {
        HostTemporaryFile(handle: try await callHostChecked(.makeTemporaryFile, []).text)
    }

    func removeAll() async {}
}

struct HostTemporaryFile: TemporaryFileWriting {
    /// The host's number for the file.
    let handle: String

    func append(_ bytes: [UInt8]) async throws {
        _ = try await callHostChecked(.appendToTemporaryFile, [handle], bytes)
    }

    func finish() async throws -> any RandomAccessSource {
        let texts = try await callHostChecked(.finishTemporaryFile, [handle]).texts
        guard texts.count == 2, let index = Int(texts[0]), let size = UInt64(texts[1]) else {
            throw ReportedError("the plugin's host gave no temporary file")
        }
        return HostSource(index: index, size: size)
    }
}
#endif
