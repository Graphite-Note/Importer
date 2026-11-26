/**
 * File: NotionDateParserTests.swift
 * ---------------------------------
 * Layer: Tests
 * Description: Notion's written dates read into property dates: month names in several languages, numeric dates in
 *              either order, times, ranges and dates without a year.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import NotionImport
import Testing

@Suite("Notion's dates")
struct NotionDateParserTests {
    private let parser = NotionDateParser(defaultYear: 2024)

    @Test("Dates and times as Notion writes them", arguments: [
        ("@February 25, 2021", "2021-02-25"), ("Feb 25, 2021 3:30 PM", "2021-02-25T15:30"),
        ("25 février 2021", "2021-02-25"), ("25. Februar 2021 14:05", "2021-02-25T14:05"),
        ("25 de febrero de 2021", "2021-02-25"), ("2021/02/25", "2021-02-25"), ("2021年2月25日", "2021-02-25"),
        ("2021-02-25T09:00:00.000+01:00", "2021-02-25T09:00"), ("March 1", "2024-03-01"),
        ("25/02/2021", "2021-02-25"), ("02/25/2021", "2021-02-25"), ("March 1, 2024 12:00 AM", "2024-03-01"),
        ("March 1, 2024 10:00 AM (GMT+2)", "2024-03-01T10:00"),
    ])
    func dates(text: String, expected: String) {
        #expect(parser.parse(text)?.propertyText == expected)
    }

    @Test("A numeric date whose order cannot be told stays unread until the export tells it")
    func ambiguousOrder() {
        var parser = self.parser
        #expect(parser.parse("03/04/2021") == nil)
        parser.observe("25/03/2021")
        #expect(parser.parse("03/04/2021")?.propertyText == "2021-04-03")
    }

    @Test("A range gives both ends, and an end of the same day may give its time alone")
    func ranges() {
        #expect(parser.parseRange("March 1, 2024 → March 5, 2024")?.map(\.propertyText) == ["2024-03-01", "2024-03-05"])
        #expect(parser.parseRange("March 1, 2024 9:00 AM → 11:30 AM")?.map(\.propertyText) == ["2024-03-01T09:00", "2024-03-01T11:30"])
        #expect(parser.parseRange("someday") == nil)
        #expect(parser.parse("February 30, 2024") == nil)
    }
}
