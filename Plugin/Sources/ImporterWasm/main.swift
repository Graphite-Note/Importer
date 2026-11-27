/**
 * File: main.swift
 * ----------------
 * Layer: Plugin
 * Description: The exports the JavaScript plugin calls: starting a Notion import over the picked files, stopping it,
 *              and the names a title gets in the vault. Text crosses as UTF-8 in the module's memory, written by the
 *              host into room from `importer_alloc`.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

#if os(WASI)
import ImporterCore
import NotionImport

nonisolated(unsafe) var runningImport: Task<Void, Never>?

private func texts(_ pointer: UnsafeMutablePointer<UInt8>?, _ count: Int32) -> [String] {
    guard let pointer, count > 0 else { return [] }
    return UnsafeBufferPointer(start: pointer, count: Int(count)).split(separator: 0, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
}

private func finish(_ status: Int32, _ texts: [String]) {
    var bytes: [UInt8] = []
    for (index, text) in texts.enumerated() {
        if index > 0 { bytes.append(0) }
        bytes.append(contentsOf: text.utf8)
    }
    bytes.withUnsafeBufferPointer { hostFinished(status, $0.baseAddress, Int32($0.count)) }
}

/// Starts a Notion import. The arguments, separated by NUL: the vault folder to import into ("" for the vault's
/// own), the export's name for the report, the day (`2026-11-27`), the year of the export, then for each picked file
/// its host number, its size and its name. The host hears of each page through `progress` and of the end through
/// `finished`: status 0 with the report's path, "1" when the import was stopped, and the notes, bases and attachments
/// written and the findings simplified, left out and failed; status 1 with the reason the import could not start.
@_expose(wasm, "importer_notion_import")
@_cdecl("importer_notion_import")
public func importerNotionImport(_ pointer: UnsafeMutablePointer<UInt8>?, _ count: Int32) {
    let arguments = texts(pointer, count)
    runningImport = Task {
        do {
            guard arguments.count >= 7, (arguments.count - 4) % 3 == 0, let year = Int(arguments[3]) else {
                throw ReportedError("the plugin gave the import no file")
            }
            let folderNames = arguments[0].split(separator: "/").map(String.init)
            guard let folder = folderNames.isEmpty ? VaultPath.vaultFolder : VaultPath(components: folderNames) else {
                throw ReportedError("“\(arguments[0])” is not a folder of the vault")
            }
            var sources: [any RandomAccessSource] = []
            var names: [String] = []
            var position = 4
            while position + 2 < arguments.count {
                guard let index = Int(arguments[position]), let size = UInt64(arguments[position + 1]) else {
                    throw ReportedError("the plugin gave a file without its size")
                }
                sources.append(HostSource(index: index, size: size))
                names.append(arguments[position + 2])
                position += 3
            }
            let tree = try await ExportFileTree.reading(zipArchives: sources, named: names,
                                                        temporaryStorage: HostTemporaryStorage())
            let options = NotionHTMLImportOptions(destinationFolder: folder, exportName: arguments[1], importDate: arguments[2],
                                                  exportYear: year, progress: { done, total in
                                                      hostProgress(Int32(clamping: done), Int32(clamping: total))
                                                  })
            let result = try await NotionHTMLImporter.importExport(tree, into: HostDestination(), options: options)
            let findings = result.report.findings
            finish(0, [
                result.reportPath.description, result.wasCancelled ? "1" : "0",
                String(result.report.writtenCount(of: .note)), String(result.report.writtenCount(of: .base)),
                String(result.report.writtenCount(of: .attachment)),
                String(findings.filter { $0.severity == .simplified }.count),
                String(findings.filter { $0.severity == .leftOut }.count),
                String(findings.filter { $0.severity == .failed }.count),
            ])
        } catch let error as NotionImportError {
            finish(1, [error.description])
        } catch {
            finish(1, [ImportReport.text(describing: error)])
        }
        runningImport = nil
    }
    runQueuedJobs()
}

/// Stops the running import at its next page. It still ends with `finished`, its report written.
@_expose(wasm, "importer_cancel")
@_cdecl("importer_cancel")
public func importerCancel() {
    runningImport?.cancel()
    runQueuedJobs()
}
#else
print("ImporterWasm is the Notion importer plugin's WebAssembly module. Build it with Plugin/build-plugin.sh.")
#endif
