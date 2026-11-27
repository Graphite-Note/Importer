/**
 * File: TextFunctionsTests.swift
 * ------------------------------
 * Layer: Tests
 * Description: The text functions written for the standard library, each checked against the Foundation function it
 *              stands in for, on texts with accents, emoji, line breaks, Unicode spaces and percent escapes.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import Foundation
@testable import ImporterCore
import Testing

private let samples = [
    "", " ", "\t", "\n", " \t\n\r ", "plain", "  two  words  ", "\u{00A0}nbsp\u{00A0}", "\u{2003}em space\u{3000}",
    "\u{2028}line separator\u{2029}", "\u{85}next line\u{85}", "a\r\nb", "\r\n", " é café ", "e\u{301} decomposed ",
    "🇨🇭 flag", " 👩🏽‍💻 ", "日本語 テキスト", "a, b, c", ",,a,,", "→ range →", "2021年2月25日", "x|y|z", "[[link]]",
    "<a>&amp;</a>", "trailing\u{0}nul", "Lecture 3: Fourier / Laplace",
]

@Suite("Text functions, the same as Foundation's")
struct TextFunctionsTests {
    @Test("Trimming spaces, tabs and line breaks")
    func trimming() {
        for sample in samples {
            #expect(sample.trimmingSpaces() == sample.trimmingCharacters(in: .whitespaces), "\(sample.debugDescription)")
            #expect(sample.trimmingSpacesAndLineBreaks() == sample.trimmingCharacters(in: .whitespacesAndNewlines),
                    "\(sample.debugDescription)")
            #expect(sample.trimming(anyOf: ", ") == sample.trimmingCharacters(in: CharacterSet(charactersIn: ", ")),
                    "\(sample.debugDescription)")
            #expect(sample[...].trimmingSpaces() == sample.trimmingCharacters(in: .whitespaces))
        }
    }

    @Test("Replacing and splitting at a text")
    func replacingAndSplitting() {
        // Foundation compares by canonical equivalence and keeps a combining accent with its letter, where these
        // compare scalar by scalar, as Foundation's literal search does: only texts without combining marks or a
        // carriage return before a line break are compared here (the next test covers those).
        for sample in samples where !sample.unicodeScalars.contains("\u{301}") && !sample.unicodeScalars.contains("\r") {
            for target in [" ", ",", ", ", "\n", "|", "→", "[", "]]", "é", "e", "🇨🇭", "xyz-absent"] {
                #expect(sample.replacingEvery(target, with: "_") == sample.replacingOccurrences(of: target, with: "_"),
                        "\(sample.debugDescription) \(target.debugDescription)")
                #expect(sample.pieces(separatedBy: target) == sample.components(separatedBy: target),
                        "\(sample.debugDescription) \(target.debugDescription)")
                #expect(sample.contains(text: target) == (sample.range(of: target) != nil))
            }
            let separators = "-/.年月日년월일 "
            #expect(sample.pieces(separatedByAnyOf: separators)
                    == sample.components(separatedBy: CharacterSet(charactersIn: separators)), "\(sample.debugDescription)")
        }
    }

    @Test("Texts are compared scalar by scalar, as Foundation's literal search compares them")
    func scalarByScalar() {
        let decomposed = "e\u{301} and é"
        #expect(decomposed.replacingEvery("é", with: "_") == "e\u{301} and _")
        #expect(decomposed.replacingEvery("é", with: "_") == decomposed.replacingOccurrences(of: "é", with: "_", options: .literal))
        #expect(decomposed.pieces(separatedBy: "e") == ["", "\u{301} and é"])
        #expect("a\r\nb".replacingEvery("\n", with: " ") == "a\r b")
        #expect("a\r\nb".replacingEvery("\n", with: " ") == "a\r\nb".replacingOccurrences(of: "\n", with: " "))
        #expect("a\r\nb".contains(text: "\n"))
    }

    @Test("Finding a text, in all of a text or in a range of it")
    func finding() throws {
        let html = "<p>one</p><time>a</time> é <time>b</time><p>two</p>"
        #expect(html.range(ofText: "<time>") == html.range(of: "<time>"))
        let first = try #require(html.range(ofText: "</time>"))
        #expect(html.range(ofText: "<time>", in: first.upperBound..<html.endIndex)
                == html.range(of: "<time>", range: first.upperBound..<html.endIndex))
        #expect(html.range(ofText: "absent") == nil)
        #expect(html.range(ofText: "") == nil)
        #expect(String(html[try #require(html.range(ofText: "é"))]) == "é")
    }

    @Test("Percent escapes decoded, refused where Foundation refuses them")
    func percentDecoding() {
        for text in ["plain", "a%20b", "%E2%86%92", "caf%C3%A9", "100%", "%zz", "%4", "%FF", "%C3", "%%", "a%2Fb", ""] {
            #expect(text.percentDecoded == text.removingPercentEncoding, "\(text)")
        }
    }

    @Test("A web address's host, path and fragment, as Foundation's URL reads them")
    func webAddresses() throws {
        let addresses = [
            "https://www.notion.so/Title-0123456789abcdef0123456789abcdef?pvs=4#fedcba98765432100123456789abcdef",
            "https://notion.so/workspace/Page-0123456789abcdef0123456789abcdef", "http://user@example.com:8080/a%20b/c",
            "https://team.notion.site/Page-0123456789abcdef0123456789abcdef#x", "https://example.com",
            "https://example.com/?q=1", "notion://www.notion.so/Page",
        ]
        for text in addresses {
            let address = try #require(WebAddress(text))
            let url = try #require(URL(string: text))
            #expect(address.host == url.host, "\(text)")
            #expect(address.path == (url.path.isEmpty ? "/" : url.path), "\(text)")
            #expect(address.fragment == url.fragment, "\(text)")
            #expect(address.scheme == url.scheme?.lowercased(), "\(text)")
        }
        #expect(WebAddress("mailto:someone@example.com") == nil)
        #expect(WebAddress("Page%20name.html") == nil)
        #expect(WebAddress("https:///no-host") == nil)
    }
}
