/**
 * File: ImportReport.swift
 * ------------------------
 * Layer: Core
 * Description: What an import did, kept as a note in the import's folder: every note, base and attachment written,
 *              what was simplified on the way, what was left out and why, and what failed.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
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
