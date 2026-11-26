/**
 * File: NotionDateParser.swift
 * ----------------------------
 * Layer: Notion
 * Description: Reads the dates Notion's HTML export writes in properties ("@February 25, 2021", "25/02/2021 3:30 PM",
 *              "2021年2月25日", ranges with "→") into the dates and times of Obsidian properties.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

/// A date read from Notion's export: the day, and the time when one was written.
public struct NotionDate: Equatable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    /// Hours and minutes, `nil` for a date alone.
    public var time: (hour: Int, minute: Int)?

    public static func == (left: NotionDate, right: NotionDate) -> Bool {
        left.year == right.year && left.month == right.month && left.day == right.day
            && left.time?.hour == right.time?.hour && left.time?.minute == right.time?.minute
    }

    /// The date as an Obsidian property writes it: `2024-03-01`, or `2024-03-01T14:30` with a time.
    public var propertyText: String {
        func padded(_ number: Int, _ width: Int) -> String {
            let digits = String(number)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let date = "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
        guard let time else { return date }
        return date + "T\(padded(time.hour, 2)):\(padded(time.minute, 2))"
    }
}

/// Reads Notion's written dates. The language of the export is not stated, so month names of the languages Notion is
/// used in most are all known, and a numeric date (`03/04/2021`) is read day first or month first as the dates seen
/// so far in the export tell (a day over 12 settles it). An order that cannot be told leaves the value as text. A date
/// written without a year takes `defaultYear`, the year of the export.
public struct NotionDateParser: Sendable {
    /// The order of numeric dates, once one has settled it.
    public enum NumericOrder: Sendable {
        case dayFirst, monthFirst
    }

    public private(set) var numericOrder: NumericOrder?
    /// The year given to dates written without one.
    public var defaultYear: Int

    public init(defaultYear: Int) {
        self.defaultYear = defaultYear
    }

    /// Learns the order of numeric dates from `text` when a day over 12 makes it plain.
    public mutating func observe(_ text: String) {
        guard numericOrder == nil, let (first, second, _) = NotionDateParser.numericParts(of: dateAndTime(of: text).date) else {
            return
        }
        if first > 12, second <= 12 { numericOrder = .dayFirst }
        if second > 12, first <= 12 { numericOrder = .monthFirst }
    }

    /// The dates of `text`: one, or two for a range written with "→". `nil` when one of them cannot be read.
    public func parseRange(_ text: String) -> [NotionDate]? {
        let parts = NotionDateParser.normalized(text).components(separatedBy: "→").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count <= 2, let start = parse(parts[0]) else { return nil }
        guard parts.count == 2 else { return [start] }
        // A range ending the same day may give the end's time alone.
        if let time = NotionDateParser.parseTime(parts[1]) {
            var end = start
            end.time = time
            return [start, end]
        }
        guard let end = parse(parts[1]) else { return nil }
        return [start, end]
    }

    /// The date of `text`, `nil` when it cannot be read.
    public func parse(_ text: String) -> NotionDate? {
        let (datePart, timeText) = dateAndTime(of: NotionDateParser.normalized(text))
        var time: (hour: Int, minute: Int)?
        if let timeText {
            guard let parsedTime = NotionDateParser.parseTime(timeText) else { return nil }
            time = parsedTime
        }
        guard var date = parseDate(datePart) else { return nil }
        if let time, time.hour != 0 || time.minute != 0 { date.time = time }
        return date
    }

    // MARK: Parts

    private static func normalized(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("@") { result.removeFirst() }
        result = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // A zoned time ends in "(GMT+2)" or "(PDT)": the time as written is what is kept.
        if result.hasSuffix(")"), let open = result.lastIndex(of: "(") {
            result = String(result[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private func dateAndTime(of text: String) -> (date: String, time: String?) {
        if text.count >= 10, text.prefix(10).allSatisfy({ $0.isNumber || $0 == "-" }), let isoTime = text.split(separator: "T").dropFirst().first {
            return (String(text.prefix(10)), String(isoTime.prefix(5)))
        }
        let words = text.split(separator: " ").map(String.init)
        for count in [2, 1] where words.count > count {
            let candidate = words.suffix(count).joined(separator: " ")
            if NotionDateParser.parseTime(candidate) != nil, candidate.contains(":") {
                let date = words.dropLast(count).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                return (date, candidate)
            }
        }
        return (text.trimmingCharacters(in: CharacterSet(charactersIn: ", ")), nil)
    }

    private static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        var rest = text.lowercased().replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where rest.hasSuffix(suffix) {
            meridiem = suffix
            rest.removeLast(2)
        }
        let pieces = rest.split(separator: ":")
        guard pieces.count == 2 || pieces.count == 3, let hour = Int(pieces[0]), let minute = Int(pieces[1]),
            (0..<60).contains(minute)
        else { return nil }
        switch meridiem {
        case "am"?:
            guard (1...12).contains(hour) else { return nil }
            return (hour == 12 ? 0 : hour, minute)
        case "pm"?:
            guard (1...12).contains(hour) else { return nil }
            return (hour == 12 ? 12 : hour + 12, minute)
        default:
            guard (0..<24).contains(hour) else { return nil }
            return (hour, minute)
        }
    }

    private static func numericParts(of text: String) -> (Int, Int, Int)? {
        for separator in ["/", ".", "-"] {
            let pieces = text.components(separatedBy: separator)
            guard pieces.count == 3, pieces[2].count == 4, let first = Int(pieces[0]), let second = Int(pieces[1]),
                let year = Int(pieces[2]), pieces[0].count <= 2, pieces[1].count <= 2
            else { continue }
            return (first, second, year)
        }
        return nil
    }

    private func parseDate(_ text: String) -> NotionDate? {
        // 2021-02-25, 2021/02/25, 2021年2月25日, 2021년 2월 25일.
        let yearFirstSeparators = CharacterSet(charactersIn: "-/.年月日년월일 ")
        let yearFirst = text.components(separatedBy: yearFirstSeparators).filter { !$0.isEmpty }
        if yearFirst.count == 3, yearFirst[0].count == 4, let year = Int(yearFirst[0]), let month = Int(yearFirst[1]),
            let day = Int(yearFirst[2])
        {
            return NotionDateParser.valid(year, month, day)
        }
        if let (first, second, year) = NotionDateParser.numericParts(of: text) {
            let order: NumericOrder?
            if first > 12, second <= 12 {
                order = .dayFirst
            } else if second > 12, first <= 12 {
                order = .monthFirst
            } else if first == second {
                order = .monthFirst
            } else {
                order = numericOrder
            }
            guard let order else { return nil }
            return order == .dayFirst ? NotionDateParser.valid(year, second, first) : NotionDateParser.valid(year, first, second)
        }
        return parseNamedDate(text)
    }

    private func parseNamedDate(_ text: String) -> NotionDate? {
        // "February 25, 2021", "Feb 25", "25 February 2021", "25. Februar 2021", "25 de febrero de 2021".
        let words = text.lowercased().replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: " de ", with: " ")
            .split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
        guard words.count == 2 || words.count == 3 else { return nil }
        let year = words.count == 3 ? Int(words[2]) : defaultYear
        guard let year, words.count == 2 || words[2].count == 4 else { return nil }
        if let month = NotionDateParser.monthNumbers[words[0]], let day = Int(words[1]) {
            return NotionDateParser.valid(year, month, day)
        }
        if let day = Int(words[0]), let month = NotionDateParser.monthNumbers[words[1]] {
            return NotionDateParser.valid(year, month, day)
        }
        return nil
    }

    private static func valid(_ year: Int, _ month: Int, _ day: Int) -> NotionDate? {
        guard (1...12).contains(month), day >= 1 else { return nil }
        let daysInMonth = [31, (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= daysInMonth[month - 1] else { return nil }
        return NotionDate(year: year, month: month, day: day, time: nil)
    }

    /// Month names, long and short, in English, French, German, Spanish, Portuguese, Italian and Dutch, in lowercase
    /// without their final dot.
    private static let monthNumbers: [String: Int] = {
        let names: [[String]] = [
            ["january", "jan", "janvier", "janv", "januar", "jän", "enero", "ene", "janeiro", "gennaio", "gen", "januari"],
            ["february", "feb", "février", "févr", "fevrier", "februar", "febrero", "fevereiro", "fev", "febbraio", "februari"],
            ["march", "mar", "mars", "märz", "mär", "marzo", "março", "marco", "maart", "mrt"],
            ["april", "apr", "avril", "avr", "abril", "abr", "aprile"],
            ["may", "mai", "mayo", "maio", "maggio", "mag", "mei"],
            ["june", "jun", "juin", "juni", "junio", "junho", "giugno", "giu"],
            ["july", "jul", "juillet", "juil", "juli", "julio", "julho", "luglio", "lug"],
            ["august", "aug", "août", "aout", "agosto", "ago", "augustus"],
            ["september", "sep", "sept", "septembre", "septiembre", "setembro", "set", "settembre"],
            ["october", "oct", "octobre", "oktober", "okt", "octubre", "outubro", "out", "ottobre", "ott"],
            ["november", "nov", "novembre", "noviembre", "novembro"],
            ["december", "dec", "décembre", "déc", "decembre", "dezember", "dez", "diciembre", "dic", "dezembro", "dicembre"],
        ]
        var table: [String: Int] = [:]
        for (index, monthNames) in names.enumerated() {
            for name in monthNames { table[name] = index + 1 }
        }
        return table
    }()
}
