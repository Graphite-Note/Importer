/**
 * File: NotionExportEntryName.swift
 * ---------------------------------
 * Layer: Notion
 * Description: Reads the name Notion's HTML export gives a page's file or folder ("Week 1 3f2a….html") into the
 *              title it starts with and the page's identifier it ends with.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

/// The name of an entry of Notion's HTML export, read.
///
/// Notion names each page's file, and the folder of its subpages, after the page's title followed by a space and the
/// page's identifier, 32 hexadecimal digits: `Week 1 3f2a9c4e1b7d4e0f8a6b5c4d3e2f1a0b.html`. A database's table is
/// `<title> <identifier>.csv`, with all its rows in `<title> <identifier>_all.csv`. The title in the name is Notion's
/// shortened and cleaned copy: the page's own title is read from the page. The identifier links the entry to the
/// links that other pages make to it.
public struct NotionExportEntryName: Equatable, Sendable {
    /// The title at the start of the name, as Notion wrote it there.
    public let title: String
    /// The page's identifier, written as Notion's API writes it: 32 lowercase hexadecimal digits in groups of 8, 4, 4,
    /// 4 and 12, between hyphens.
    public let pageIdentifier: String
    /// The extension of a file (`html`, `csv`, `md`), `nil` for a folder.
    public let pathExtension: String?
    /// Whether the entry is the `_all.csv` table of a database holding all its rows.
    public let isAllRowsTable: Bool

    /// The name `entryName` read, or `nil` when it does not end with a page identifier.
    public init?(_ entryName: String) {
        var stem = Substring(entryName)
        var pathExtension: String?
        if let dot = stem.lastIndex(of: "."), stem[stem.index(after: dot)...].allSatisfy({ $0.isLetter }),
            stem.index(after: dot) != stem.endIndex
        {
            pathExtension = stem[stem.index(after: dot)...].lowercased()
            stem = stem[..<dot]
        }
        var isAllRowsTable = false
        if pathExtension == "csv", stem.hasSuffix("_all") {
            isAllRowsTable = true
            stem = stem.dropLast(4)
        }
        let digits = stem.suffix(32)
        guard digits.count == 32, digits.allSatisfy(\.isHexDigit) else { return nil }
        let beforeDigits = stem.dropLast(32)
        guard beforeDigits.isEmpty || beforeDigits.hasSuffix(" ") else { return nil }
        self.title = String(beforeDigits.dropLast(beforeDigits.isEmpty ? 0 : 1))
        self.pageIdentifier = NotionExportEntryName.hyphenated(digits.lowercased())
        self.pathExtension = pathExtension
        self.isAllRowsTable = isAllRowsTable
    }

    private static func hyphenated(_ digits: String) -> String {
        var groups: [Substring] = []
        var start = digits.startIndex
        for length in [8, 4, 4, 4, 12] {
            let end = digits.index(start, offsetBy: length)
            groups.append(digits[start..<end])
            start = end
        }
        return groups.joined(separator: "-")
    }
}
