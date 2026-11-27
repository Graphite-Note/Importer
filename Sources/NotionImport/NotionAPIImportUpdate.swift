/**
 * File: NotionAPIImportUpdate.swift
 * ---------------------------------
 * Layer: Notion
 * Description: Importing a workspace again over an earlier import: the record an import leaves of what it wrote, the
 *              earlier notes found by their notion-id, and each note or base replaced only while it is still what the
 *              earlier import wrote.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import ImporterCore

/// What an import wrote, kept in its folder as `.notion-import.json` for the next import of the same workspace: each
/// page's note and database's base, by Notion's identifier, with the fingerprint of the bytes written.
struct NotionAPIImportRecord: Equatable {
    struct Entry: Equatable {
        var path: VaultPath
        /// The fingerprint of what the import wrote, `nil` when it is not known (a note found by its `notion-id` with no
        /// record), so the note is never replaced.
        var fingerprint: String?
    }

    static let fileName = ".notion-import.json"

    var entries: [String: Entry] = [:]

    /// The record's JSON.
    var json: JSONValue {
        .object([
            ("notion-import", .number("1")),
            ("entries", .array(entries.sorted { $0.key < $1.key }.map { key, entry in
                .object([("id", .string(key)), ("path", .string(entry.path.description)), ("fingerprint", entry.fingerprint.map { JSONValue.string($0) } ?? .null)])
            })),
        ])
    }

    init() {}

    /// The record read from its JSON, `nil` when it is not one.
    init?(_ json: JSONValue) {
        guard json["notion-import"] != nil, let list = json["entries"]?.elements else { return nil }
        for entry in list {
            guard let key = entry["id"]?.string, let text = entry["path"]?.string,
                let path = VaultPath(components: text.pieces(separatedBy: "/"))
            else { continue }
            entries[key] = Entry(path: path, fingerprint: entry["fingerprint"]?.string)
        }
    }

    /// The `notion-id` in the front matter of a note's text, `nil` when it has none.
    static func notionIdentifier(inNote text: String) -> String? {
        let lines = text.pieces(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard line.hasPrefix("notion-id:") else { continue }
            var value = Substring(line.dropFirst("notion-id:".count))
            while value.first == " " { value = value.dropFirst() }
            while value.last == " " || value.last == "\r" { value = value.dropLast() }
            if value.first == "\"" || value.first == "'", value.count >= 2 { value = value.dropFirst().dropLast() }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }
}

extension NotionAPIImportRun {
    var recordPath: VaultPath? { rootFolder.appending(NotionAPIImportRecord.fileName) }

    /// Finds what an earlier import wrote in the import's folder: its record, and the notes there with a `notion-id`,
    /// which also finds a note moved within the folder since.
    mutating func readEarlierImport() async throws {
        guard let updater, let recordPath else { return }
        var record = NotionAPIImportRecord()
        if let bytes = try await updater.readFile(at: recordPath) {
            if let json = try? JSONValue.parse(bytes), let read = NotionAPIImportRecord(json) {
                record = read
            } else {
                report.record(.simplified, at: nil, "the record of the earlier import could not be read, so none of its notes is replaced")
            }
        }
        var found: [String: VaultPath] = [:]
        for path in try await updater.filePaths(inFolderAt: rootFolder) where path.name.hasSuffix(".md") {
            guard let bytes = try await updater.readFile(at: path),
                let identifier = NotionAPIImportRecord.notionIdentifier(inNote: String(decoding: bytes, as: UTF8.self))
            else { continue }
            found[NotionAPIImportRun.key(identifier)] = path
        }
        for (key, entry) in record.entries {
            if entry.path.name.hasSuffix(".md") {
                // A note is where its notion-id is now, and replaced only when the record knows it at that place.
                guard let path = found[key] else { continue }
                earlier[key] = path == entry.path ? entry : NotionAPIImportRecord.Entry(path: path, fingerprint: nil)
            } else if try await updater.readFile(at: entry.path) != nil {
                earlier[key] = entry
            }
        }
        for (key, path) in found where earlier[key] == nil { earlier[key] = NotionAPIImportRecord.Entry(path: path, fingerprint: nil) }
        if earlier.isEmpty {
            report.record(.simplified, at: nil, "no earlier import of this workspace was found in this folder, so everything was imported as new")
        }
    }

    /// Writes a page's note or a database's base. Updating, a file of the earlier import is replaced only when it still
    /// holds what that import wrote, and kept and reported otherwise.
    mutating func save(_ contents: [UInt8], of item: NotionAPIItem, kind: ImportReport.WrittenKind) async throws {
        let key = NotionAPIImportRun.key(item.identifier)
        let fingerprint = ContentFingerprint.of(contents)
        guard let updater, let previous = earlier[key], previous.path == item.path, let current = try await updater.readFile(at: item.path) else {
            try await destination.writeNewFile(contents, at: item.path)
            report.recordWritten(kind, at: item.path)
            record.entries[key] = NotionAPIImportRecord.Entry(path: item.path, fingerprint: fingerprint)
            return
        }
        if current == contents {
            updateCounts.unchanged += 1
            record.entries[key] = NotionAPIImportRecord.Entry(path: item.path, fingerprint: fingerprint)
            return
        }
        if let earlierFingerprint = previous.fingerprint, earlierFingerprint == ContentFingerprint.of(current) {
            do {
                try await updater.replaceFile(at: item.path, expecting: current, with: contents)
                updateCounts.replaced += 1
                report.recordWritten(kind, at: item.path)
                record.entries[key] = NotionAPIImportRecord.Entry(path: item.path, fingerprint: fingerprint)
                return
            } catch let error as ImportUpdateError {
                // Changed while the import ran: kept as below.
                _ = error
            }
        }
        updateCounts.kept += 1
        report.record(.leftOut, at: item.path, "“\(item.title)” changed in the vault since the earlier import, so Notion's version was not written "
            + "over it (moving it out of this folder or deleting it lets the next import write Notion's version)")
        // Still protected next time: its fingerprint is unknown.
        record.entries[key] = NotionAPIImportRecord.Entry(path: item.path, fingerprint: nil)
    }

    /// Writes the record of this import for the next one, over the earlier record when updating.
    mutating func writeRecord() async throws {
        guard let recordPath else { return }
        // The notes and bases this import did not reach keep their earlier entries.
        for (key, entry) in earlier where record.entries[key] == nil { record.entries[key] = entry }
        let contents = Array(record.json.text.utf8)
        do {
            if let updater, let current = try await updater.readFile(at: recordPath) {
                try await updater.replaceFile(at: recordPath, expecting: current, with: contents)
            } else {
                try await destination.writeNewFile(contents, at: recordPath)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            report.record(.simplified, at: nil, "the record of this import could not be written (\(ImportReport.text(describing: error))), "
                + "so importing again will replace none of its notes")
        }
    }
}
