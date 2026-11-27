/**
 * File: HostBridge.swift
 * ----------------------
 * Layer: Plugin
 * Description: The calls between the WebAssembly module and the JavaScript plugin around it. Every read, write and
 *              request is one host call that JavaScript answers later through `importer_resume`, so Swift's async
 *              code waits for the host without blocking it.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

#if os(WASI)
import ImporterCore

// MARK: The host's functions

/// Asks the host for `kind`, with `argument` (texts separated by NUL) and `bytes`. The host answers later with
/// `importer_resume(request, status, bytes)`, never during this call.
@_extern(wasm, module: "importer_host", name: "call")
@_extern(c)
func hostCall(_ request: Int32, _ kind: Int32, _ argument: UnsafePointer<UInt8>?, _ argumentCount: Int32,
              _ bytes: UnsafePointer<UInt8>?, _ byteCount: Int32)

/// Tells the host how many pages are done, of how many.
@_extern(wasm, module: "importer_host", name: "progress")
@_extern(c)
func hostProgress(_ done: Int32, _ total: Int32)

/// Tells the host the import ended: `status` 0 with its summary, else 1 with the reason.
@_extern(wasm, module: "importer_host", name: "finished")
@_extern(c)
func hostFinished(_ status: Int32, _ bytes: UnsafePointer<UInt8>?, _ count: Int32)

@_silgen_name("swift_task_donateThreadToGlobalExecutorUntil")
func donateThreadToGlobalExecutor(_ condition: @convention(c) (UnsafeMutableRawPointer?) -> Bool,
                                  _ context: UnsafeMutableRawPointer?)

/// Runs every job the cooperative executor holds, until each task waits on the host again.
func runQueuedJobs() {
    donateThreadToGlobalExecutor({ _ in false }, nil)
}

// MARK: Host calls as async functions

/// What the host can be asked for. The numbers are the plugin's (`importer-engine.js`).
enum HostKind: Int32 {
    case read = 1
    case createFolder = 2
    case writeNewFile = 3
    case createNewFile = 4
    case appendToFile = 5
    case closeFile = 6
    case names = 7
    case assignPropertyTypes = 8
    case makeTemporaryFile = 9
    case appendToTemporaryFile = 10
    case finishTemporaryFile = 11
    case request = 12
}

/// The host's answer: its status and its bytes.
struct HostAnswer {
    /// 0 when the call succeeded, 17 when a file was already there, 1 when it failed (`bytes` then says why), an HTTP
    /// status for a request.
    var status: Int32
    var bytes: [UInt8]

    /// The answer's bytes as UTF-8 text.
    var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// The answer's texts, separated by NUL.
    var texts: [String] {
        bytes.isEmpty ? [] : bytes.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Status 17, as POSIX numbers "file exists".
let fileExistsStatus: Int32 = 17

nonisolated(unsafe) var waitingCalls: [Int32: UnsafeContinuation<HostAnswer, Never>] = [:]
nonisolated(unsafe) var nextRequest: Int32 = 1

/// Asks the host for `kind` and waits for its answer.
func callHost(_ kind: HostKind, _ arguments: [String], _ bytes: [UInt8] = []) async -> HostAnswer {
    let request = nextRequest
    nextRequest += 1
    var argumentBytes: [UInt8] = []
    for (index, argument) in arguments.enumerated() {
        if index > 0 { argumentBytes.append(0) }
        argumentBytes.append(contentsOf: argument.utf8)
    }
    return await withUnsafeContinuation { continuation in
        waitingCalls[request] = continuation
        argumentBytes.withUnsafeBufferPointer { argumentBuffer in
            bytes.withUnsafeBufferPointer { byteBuffer in
                hostCall(request, kind.rawValue, argumentBuffer.baseAddress, Int32(argumentBuffer.count), byteBuffer.baseAddress,
                         Int32(byteBuffer.count))
            }
        }
    }
}

/// Asks the host for `kind` and throws when it failed: `ImportDestinationError.fileAlreadyExists` for status 17 when
/// `path` is given, else the host's reason.
func callHostChecked(_ kind: HostKind, _ arguments: [String], _ bytes: [UInt8] = [], path: VaultPath? = nil) async throws -> HostAnswer {
    let answer = await callHost(kind, arguments, bytes)
    if answer.status == fileExistsStatus, let path { throw ImportDestinationError.fileAlreadyExists(path) }
    guard answer.status == 0 else { throw ReportedError(answer.bytes.isEmpty ? "the plugin's host refused the call" : answer.text) }
    return answer
}

/// Called by the host with its answer to the call `request`: resumes the task waiting for it and runs the tasks
/// until all wait on the host again. `pointer` holds `count` bytes the host wrote with `importer_alloc`, which the host
/// frees after this call.
@_expose(wasm, "importer_resume")
@_cdecl("importer_resume")
public func importerResume(_ request: Int32, _ status: Int32, _ pointer: UnsafeMutablePointer<UInt8>?, _ count: Int32) {
    let bytes = pointer.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) } ?? []
    waitingCalls.removeValue(forKey: request)?.resume(returning: HostAnswer(status: status, bytes: bytes))
    runQueuedJobs()
}

/// Room for `count` bytes the host writes into the module's memory.
@_expose(wasm, "importer_alloc")
@_cdecl("importer_alloc")
public func importerAlloc(_ count: Int32) -> UnsafeMutablePointer<UInt8> {
    UnsafeMutablePointer<UInt8>.allocate(capacity: Int(max(count, 1)))
}

/// Frees room given by `importer_alloc`.
@_expose(wasm, "importer_free")
@_cdecl("importer_free")
public func importerFree(_ pointer: UnsafeMutablePointer<UInt8>) {
    pointer.deallocate()
}
#endif
