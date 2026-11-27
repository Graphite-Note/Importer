/**
 * File: ImportReport.swift
 * ------------------------
 * Layer: Core
 * Description: What an import did, kept as a note in the import's folder: every note, base and attachment written,
 *              what was simplified on the way, what was left out and why, and what failed.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

/// The record of one import, written as a note when the import ends.
public struct ImportReport: Equatable, Sendable {
    /// How serious a finding is.
    public enum Severity: String, Equatable, Sendable, CaseIterable {
        /// Imported, but in a simpler form than the source had (a column layout flattened, a color dropped).
        case simplified
        /// Not imported, and why (a file the export lacks, an entry that could reach outside the vault).
        case leftOut
        /// Could not be imported because of an error.
        case failed
    }

    /// One thing the report says.
    public struct Finding: Equatable, Sendable {
        public var severity: Severity
        /// The vault path of the note, base or file the finding is about, `nil` for the import as a whole.
        public var path: VaultPath?
        /// What happened, in a sentence.
        public var message: String

        public init(severity: Severity, path: VaultPath?, message: String) {
            self.severity = severity
            self.path = path
            self.message = message
        }
    }

    /// The kind of file written.
    public enum WrittenKind: String, Equatable, Sendable {
        case note, base, attachment
    }

    /// The import's title, the report's heading.
    public var title: String
    /// What was imported, in a sentence (the export's name and the date).
    public var source: String
    /// Every file written, in order.
    public private(set) var written: [(kind: WrittenKind, path: VaultPath)] = []
    /// Every finding, in order.
    public private(set) var findings: [Finding] = []

    public init(title: String, source: String) {
        self.title = title
        self.source = source
    }

    public static func == (left: ImportReport, right: ImportReport) -> Bool {
        left.title == right.title && left.source == right.source && left.findings == right.findings
            && left.written.count == right.written.count
            && zip(left.written, right.written).allSatisfy { $0.kind == $1.kind && $0.path == $1.path }
    }

    /// Records that `path` was written.
    public mutating func recordWritten(_ kind: WrittenKind, at path: VaultPath) {
        written.append((kind, path))
    }

    /// Records a finding.
    public mutating func record(_ severity: Severity, at path: VaultPath?, _ message: String) {
        findings.append(Finding(severity: severity, path: path, message: message))
    }

    /// The number of files written of `kind`.
    public func writtenCount(of kind: WrittenKind) -> Int {
        written.filter { $0.kind == kind }.count
    }

    /// The report as a note's blocks. Links point at vault paths, so they resolve wherever the report is.
    public var blocks: [MarkdownBlock] {
        var blocks: [MarkdownBlock] = [.paragraph([.text(source)])]
        func count(_ number: Int, _ singular: String, _ plural: String) -> String {
            "\(number) \(number == 1 ? singular : plural)"
        }
        blocks.append(.paragraph([.text("Written: " + [
            count(writtenCount(of: .note), "note", "notes"),
            count(writtenCount(of: .base), "base", "bases"),
            count(writtenCount(of: .attachment), "attachment", "attachments"),
        ].joined(separator: ", ") + ".")]))
        let headings: [Severity: String] = [.failed: "Failed", .leftOut: "Left out", .simplified: "Simplified"]
        for severity in [Severity.failed, .leftOut, .simplified] {
            let matching = findings.filter { $0.severity == severity }
            guard !matching.isEmpty else { continue }
            blocks.append(.heading(level: 2, [.text("\(headings[severity] ?? "") (\(matching.count))")]))
            blocks.append(.bulletList(matching.map { finding in
                var inlines: [MarkdownInline] = []
                if let path = finding.path {
                    inlines.append(ImportReport.link(to: path))
                    inlines.append(.text(": "))
                }
                inlines.append(.text(finding.message))
                return MarkdownListItem(blocks: [.paragraph(inlines)])
            }))
        }
        let notes = written.filter { $0.kind != .attachment }
        if !notes.isEmpty {
            blocks.append(.heading(level: 2, [.text("Notes and bases (\(notes.count))")]))
            blocks.append(.bulletList(notes.map { MarkdownListItem(blocks: [.paragraph([ImportReport.link(to: $0.path)])]) }))
        }
        return blocks
    }

    private static func link(to path: VaultPath) -> MarkdownInline {
        var target = path.description
        if target.hasSuffix(".md") { target.removeLast(3) }
        let name = path.name.hasSuffix(".md") ? String(path.name.dropLast(3)) : path.name
        return .wikiLink(target: target, label: name, isEmbed: false)
    }

    /// The report note's Markdown.
    public var markdown: String {
        MarkdownWriter.markdown(for: [.heading(level: 1, [.text(title)])] + blocks)
    }
}

/// An error a host gives with the words the import report should show, such as a refused vault write in the
/// WebAssembly build.
public struct ReportedError: Error, Sendable, Equatable, CustomStringConvertible {
    /// What went wrong, in words.
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

extension ImportReport {
    /// The words an import report gives for `error`: the importers' own errors in sentences, any other as Swift
    /// describes it. Embedded Swift can describe only the types it is told of (it casts to concrete types alone), so
    /// an error of another type is named there by its having happened.
    public static func text(describing error: any Error) -> String {
        if let error = error as? ReportedError { return error.message }
        if let error = error as? ZipArchiveError { return error.description }
        if let error = error as? InflaterError { return error.description }
        if let error = error as? RandomAccessSourceError { return error.description }
        if let error = error as? ImportDestinationError { return error.description }
        #if hasFeature(Embedded)
        return "an error the WebAssembly build cannot describe"
        #else
        return String(describing: error)
        #endif
    }
}

extension ZipArchiveError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAZipArchive: return "the file is not a zip archive, or it was cut short"
        case .damagedArchive(let detail): return "the archive is damaged (\(detail))"
        case .encryptedEntry(let entry): return "\(entry) is encrypted"
        case .unsupportedCompressionMethod(let entry, let method):
            return "\(entry) is compressed with method \(method), which only stored (0) and deflated (8) entries are read with"
        case .checksumMismatch(let entry): return "\(entry) is damaged: its size or checksum differs from the archive's record"
        case .entryTooLarge(let entry, let size): return "\(entry) is too large to read whole (\(size) bytes)"
        }
    }
}

extension InflaterError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .reservedBlockType: return "the compressed data names a reserved block type"
        case .storedLengthMismatch: return "a stored block's length and its complement disagree"
        case .invalidCodeLengths: return "a block's code lengths describe no usable code"
        case .invalidSymbol: return "the compressed data holds a code that does not exist"
        case .distanceBeforeStart: return "the compressed data reaches back before its start"
        case .truncatedInput: return "the compressed data ends before its last block"
        }
    }
}

extension RandomAccessSourceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .rangeOutsideSource(let offset, let count, let size):
            return "\(count) bytes from byte \(offset) were asked for, past the end of the \(size)-byte file"
        }
    }
}

extension ImportDestinationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileAlreadyExists(let path): return "a file is already at \(path.description)"
        case .unreadablePropertyTypes(let path): return "\(path.description) is not the JSON object Obsidian writes, so it was left as it is"
        }
    }
}
