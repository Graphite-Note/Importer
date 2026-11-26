/**
 * File: CSVTable.swift
 * --------------------
 * Layer: Core
 * Description: Reads a CSV table (RFC 4180: commas, double quotes, line breaks inside quoted fields), as exports
 *              write their databases.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

/// A CSV table: its header and its rows.
public struct CSVTable: Equatable, Sendable {
    /// The names of the columns, from the first line.
    public let header: [String]
    /// The rows after the header, each with as many fields as it had.
    public let rows: [[String]]

    /// The table of `text`, a byte order mark at its start ignored.
    public init(_ text: String) {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var isQuoted = false
        var characters = text.unicodeScalars.makeIterator()
        var pending = characters.next()
        if pending == "\u{FEFF}" { pending = characters.next() }
        var fieldStarted = false
        while let scalar = pending {
            pending = characters.next()
            if isQuoted {
                if scalar == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = characters.next()
                    } else {
                        isQuoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty:
                isQuoted = true
                fieldStarted = true
            case ",":
                record.append(field)
                field = ""
                fieldStarted = true
            case "\r", "\n":
                if scalar == "\r", pending == "\n" { pending = characters.next() }
                if fieldStarted || !field.isEmpty || !record.isEmpty {
                    record.append(field)
                    records.append(record)
                }
                record = []
                field = ""
                fieldStarted = false
            default:
                field.unicodeScalars.append(scalar)
                fieldStarted = true
            }
        }
        if fieldStarted || !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        header = records.first ?? []
        rows = Array(records.dropFirst())
    }

    /// The value of `column` in `row`, empty when the row is shorter.
    public func value(_ column: String, in row: [String]) -> String {
        guard let index = header.firstIndex(of: column), index < row.count else { return "" }
        return row[index]
    }
}
