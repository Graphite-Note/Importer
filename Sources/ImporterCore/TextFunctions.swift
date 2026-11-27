/**
 * File: TextFunctions.swift
 * -------------------------
 * Layer: Core
 * Description: The few text functions the importers used from Foundation, written with the standard library alone
 *              so that the WebAssembly module needs no Foundation: trimming, replacing, splitting, finding text,
 *              percent decoding and reading a web address.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

extension Unicode.Scalar {
    /// A space or a tab, as Foundation's `CharacterSet.whitespaces` has them: the tab and Unicode's space separators.
    package var isSpaceOrTab: Bool {
        value == 0x09 || properties.generalCategory == .spaceSeparator
    }

    /// A space, a tab or a line break, as Foundation's `CharacterSet.whitespacesAndNewlines` has them.
    package var isSpaceOrLineBreak: Bool {
        switch value {
        case 0x09...0x0D, 0x85: return true
        default:
            switch properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
}

extension StringProtocol {
    /// The text without the spaces and tabs at its start and its end.
    package func trimmingSpaces() -> String {
        trimming { $0.isSpaceOrTab }
    }

    /// The text without the spaces, tabs and line breaks at its start and its end.
    package func trimmingSpacesAndLineBreaks() -> String {
        trimming { $0.isSpaceOrLineBreak }
    }

    /// The text without the characters of `characters` at its start and its end, compared scalar by scalar.
    package func trimming(anyOf characters: String) -> String {
        let set = Set(characters.unicodeScalars)
        return trimming { set.contains($0) }
    }

    /// The text without the scalars at its start and its end for which `shouldTrim` holds.
    package func trimming(where shouldTrim: (Unicode.Scalar) -> Bool) -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !shouldTrim($0) }),
            let last = scalars.lastIndex(where: { !shouldTrim($0) })
        else { return "" }
        return String(String.UnicodeScalarView(scalars[first...last]))
    }

    /// The range of the first place `target` is found, compared byte by byte (so scalar by scalar), searched in
    /// `searchRange` or the whole text. `nil` when it is not found or `target` is empty.
    package func range(ofText target: some StringProtocol, in searchRange: Range<Index>? = nil) -> Range<Index>? {
        let needle = Array(target.utf8)
        let view = utf8
        let lower = view.distance(from: view.startIndex, to: searchRange?.lowerBound ?? startIndex)
        let upper = view.distance(from: view.startIndex, to: searchRange?.upperBound ?? endIndex)
        guard let found = TextBytes.withBytes(of: self, { TextBytes.firstOffset(of: needle, in: $0, from: lower, to: upper) })
        else { return nil }
        return view.index(view.startIndex, offsetBy: found)..<view.index(view.startIndex, offsetBy: found + needle.count)
    }

    /// Whether `target` is found in the text, compared scalar by scalar.
    package func contains(text target: some StringProtocol) -> Bool {
        range(ofText: target) != nil
    }

    /// The text with every `target` replaced by `replacement`, compared scalar by scalar.
    package func replacingEvery(_ target: some StringProtocol, with replacement: some StringProtocol) -> String {
        let pieces = pieces(separatedBy: target)
        return pieces.count == 1 ? String(self) : pieces.joined(separator: String(replacement))
    }

    /// The pieces of the text between the places `separator` is found, empty pieces kept, as Foundation's
    /// `components(separatedBy:)` gives them.
    package func pieces(separatedBy separator: some StringProtocol) -> [String] {
        let needle = Array(separator.utf8)
        return TextBytes.withBytes(of: self) { bytes in
            guard !needle.isEmpty else { return [String(decoding: bytes, as: UTF8.self)] }
            var pieces: [String] = []
            var start = 0
            while let found = TextBytes.firstOffset(of: needle, in: bytes, from: start, to: bytes.count) {
                pieces.append(String(decoding: bytes[start..<found], as: UTF8.self))
                start = found + needle.count
            }
            pieces.append(String(decoding: bytes[start..<bytes.count], as: UTF8.self))
            return pieces
        }
    }

    /// The pieces of the text between the scalars of `separators`, empty pieces kept, as Foundation's
    /// `components(separatedBy:)` gives them for a character set.
    package func pieces(separatedByAnyOf separators: String) -> [String] {
        let set = Set(separators.unicodeScalars)
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            if set.contains(scalar) {
                pieces.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        pieces.append(String(current))
        return pieces
    }

    /// The text with its percent escapes (`%20`) decoded, as Foundation's `removingPercentEncoding` decodes them:
    /// `nil` when a `%` is not followed by two hexadecimal digits or the bytes decoded are not UTF-8.
    package var percentDecoded: String? {
        var bytes: [UInt8] = []
        var iterator = utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next().flatMap(TextBytes.hexValue), let low = iterator.next().flatMap(TextBytes.hexValue)
            else { return nil }
            bytes.append(high << 4 | low)
        }
        return String(validating: bytes, as: UTF8.self)
    }
}

/// The parts of a web address that the importers read, as Foundation's `URL` gives them for an address with a host:
/// `https://user@www.notion.so:443/Title-abc?pvs=4#def` has the host `www.notion.so`, the path `/Title-abc` and the
/// fragment `def`.
package struct WebAddress: Sendable, Equatable {
    /// The scheme, lowercased (`https`).
    package let scheme: String
    /// The host, as written (`www.notion.so`).
    package let host: String
    /// The path with its percent escapes decoded, `/` when the address has none.
    package let path: String
    /// What follows `#`, `nil` when nothing does.
    package let fragment: String?

    /// The address `text`, or `nil` when it is not of the form `scheme://host…`.
    package init?(_ text: String) {
        guard let schemeEnd = text.range(ofText: "://") else { return nil }
        let scheme = text[..<schemeEnd.lowerBound]
        guard let first = scheme.unicodeScalars.first, first.properties.isAlphabetic, first.isASCII,
            scheme.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil
                || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return nil }
        var rest = text[schemeEnd.upperBound...]
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        if let question = rest.firstIndex(of: "?") {
            rest = rest[..<question]
        }
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        if let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
            authority = authority[..<colon]
        }
        guard !authority.isEmpty else { return nil }
        let rawPath = rest[authorityEnd...]
        self.scheme = scheme.lowercased()
        self.host = String(authority)
        self.path = rawPath.isEmpty ? "/" : (rawPath.percentDecoded ?? String(rawPath))
        self.fragment = fragment
    }
}

/// Byte searches over a text's UTF-8, which find the same places a search scalar by scalar finds, since UTF-8 never
/// starts a scalar inside another.
enum TextBytes {
    static func withBytes<Text: StringProtocol, Result>(of text: Text, _ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
        return Array(text.utf8).withUnsafeBufferPointer(body)
    }

    static func firstOffset(of needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int? {
        guard let first = needle.first, end - start >= needle.count else { return nil }
        var position = start
        let last = end - needle.count
        while position <= last {
            if bytes[position] == first {
                var matched = 1
                while matched < needle.count, bytes[position + matched] == needle[matched] {
                    matched += 1
                }
                if matched == needle.count { return position }
            }
            position += 1
        }
        return nil
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
