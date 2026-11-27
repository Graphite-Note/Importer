/**
 * File: HTMLDocument.swift
 * ------------------------
 * Layer: Core
 * Description: A tolerant HTML reader that builds the tree of elements and text an export's pages are made of, written
 *              in Swift with no HTML library, so that it runs the same on Apple platforms, Linux and WebAssembly.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

/// A node of an HTML tree: an element with its attributes and children, or text.
public final class HTMLNode {
    /// What the node is.
    public enum Kind: Equatable, Sendable {
        /// An element, its tag name in lowercase.
        case element(String)
        /// Text, its character references decoded.
        case text(String)
    }

    /// What the node is.
    public let kind: Kind
    /// The element's attributes, names in lowercase, values decoded. Empty for text.
    public let attributes: [String: String]
    /// The element's children in order.
    public private(set) var children: [HTMLNode] = []
    #if hasFeature(Embedded)
    /// The element the node is in, `nil` for the root. Embedded Swift has no weak references, so there the parent is
    /// not retained, and a node must not be used once its document is gone: the importers read a node only while
    /// they hold its document.
    public private(set) unowned(unsafe) var parent: HTMLNode?
    #else
    /// The element the node is in, `nil` for the root.
    public private(set) weak var parent: HTMLNode?
    #endif

    init(kind: Kind, attributes: [String: String] = [:]) {
        self.kind = kind
        self.attributes = attributes
    }

    func append(_ child: HTMLNode) {
        child.parent = self
        children.append(child)
    }

    /// The element's tag name, `nil` for text.
    public var tagName: String? {
        if case .element(let name) = kind { return name }
        return nil
    }

    /// The text of a text node, `nil` for an element.
    public var text: String? {
        if case .text(let text) = kind { return text }
        return nil
    }

    /// The element's classes, from its `class` attribute.
    public var classes: [String] {
        (attributes["class"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// Whether the element has the class `name`.
    public func hasClass(_ name: String) -> Bool {
        classes.contains(name)
    }

    /// The element's children that are elements.
    public var elementChildren: [HTMLNode] {
        children.filter { $0.tagName != nil }
    }

    /// The text of the node and everything inside it, in order.
    public var textContent: String {
        switch kind {
        case .text(let text):
            return text
        case .element:
            var result = ""
            appendText(to: &result)
            return result
        }
    }

    private func appendText(to result: inout String) {
        for child in children {
            switch child.kind {
            case .text(let text): result += text
            case .element: child.appendText(to: &result)
            }
        }
    }

    /// The first element inside this one, in document order, for which `matches` is true.
    public func firstDescendant(where matches: (HTMLNode) -> Bool) -> HTMLNode? {
        for child in children where child.tagName != nil {
            if matches(child) { return child }
            if let found = child.firstDescendant(where: matches) { return found }
        }
        return nil
    }

    /// Every element inside this one, in document order, for which `matches` is true.
    public func descendants(where matches: (HTMLNode) -> Bool) -> [HTMLNode] {
        var found: [HTMLNode] = []
        collectDescendants(where: matches, into: &found)
        return found
    }

    private func collectDescendants(where matches: (HTMLNode) -> Bool, into found: inout [HTMLNode]) {
        for child in children where child.tagName != nil {
            if matches(child) { found.append(child) }
            child.collectDescendants(where: matches, into: &found)
        }
    }

    /// The nearest element above this one for which `matches` is true.
    public func ancestor(where matches: (HTMLNode) -> Bool) -> HTMLNode? {
        var current = parent
        while let node = current {
            if matches(node) { return node }
            current = node.parent
        }
        return nil
    }
}

/// An HTML document read into a tree.
///
/// The reader follows what exports write rather than every rule of the HTML standard: elements nest as their tags say
/// (Notion puts a `div` inside a `p`, which a browser would move out, and the nesting is what the export means), void
/// elements (`br`, `img`, `hr`, …) and self-closed tags have no children, `script`, `style` and `textarea` hold raw text,
/// an end tag closes the nearest open element of its name and the elements opened inside it, and an end tag with no
/// open element of its name is ignored. Character references are decoded in text and attribute values.
public struct HTMLDocument {
    /// The root, an element named `#document` holding the document's top elements.
    public let root: HTMLNode

    /// The document of `html`.
    public init(_ html: String) {
        var builder = HTMLTreeBuilder(html)
        root = builder.build()
    }

    /// The first element of the document for which `matches` is true.
    public func firstElement(where matches: (HTMLNode) -> Bool) -> HTMLNode? {
        root.firstDescendant(where: matches)
    }
}

private struct HTMLTreeBuilder {
    private let scalars: [Unicode.Scalar]
    private var position = 0

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]
    private static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]

    init(_ html: String) {
        scalars = Array(html.unicodeScalars)
    }

    mutating func build() -> HTMLNode {
        let root = HTMLNode(kind: .element("#document"))
        var openElements: [HTMLNode] = [root]
        var text = String.UnicodeScalarView()

        func flushText() {
            if !text.isEmpty {
                openElements[openElements.count - 1].append(HTMLNode(kind: .text(HTMLCharacterReferences.decode(String(text)))))
                text = String.UnicodeScalarView()
            }
        }

        while position < scalars.count {
            let scalar = scalars[position]
            guard scalar == "<", position + 1 < scalars.count else {
                text.append(scalar)
                position += 1
                continue
            }
            let next = scalars[position + 1]
            if next == "!" {
                flushText()
                skipMarkupDeclaration()
            } else if next == "?" {
                flushText()
                skip(past: ">")
            } else if next == "/" {
                flushText()
                position += 2
                let name = readName().lowercased()
                skip(past: ">")
                if let index = openElements.lastIndex(where: { $0.tagName == name }), index > 0 {
                    openElements.removeSubrange(index...)
                }
            } else if next.properties.isAlphabetic {
                flushText()
                position += 1
                let name = readName().lowercased()
                let (attributes, isSelfClosed) = readAttributes()
                let element = HTMLNode(kind: .element(name), attributes: attributes)
                openElements[openElements.count - 1].append(element)
                if HTMLTreeBuilder.voidElements.contains(name) || isSelfClosed {
                    continue
                }
                if HTMLTreeBuilder.rawTextElements.contains(name) {
                    let raw = readRawText(until: name)
                    if !raw.isEmpty {
                        element.append(HTMLNode(kind: .text(name == "script" || name == "style" ? raw : HTMLCharacterReferences.decode(raw))))
                    }
                    continue
                }
                openElements.append(element)
            } else {
                text.append(scalar)
                position += 1
            }
        }
        flushText()
        return root
    }

    private mutating func readName() -> String {
        var name = String.UnicodeScalarView()
        while position < scalars.count {
            let scalar = scalars[position]
            if scalar == ">" || scalar == "/" || scalar.properties.isWhitespace { break }
            name.append(scalar)
            position += 1
        }
        return String(name)
    }

    private mutating func skipWhitespace() {
        while position < scalars.count, scalars[position].properties.isWhitespace { position += 1 }
    }

    private mutating func readAttributes() -> ([String: String], Bool) {
        var attributes: [String: String] = [:]
        var isSelfClosed = false
        while position < scalars.count {
            skipWhitespace()
            guard position < scalars.count else { break }
            let scalar = scalars[position]
            if scalar == ">" {
                position += 1
                break
            }
            if scalar == "/" {
                isSelfClosed = position + 1 < scalars.count && scalars[position + 1] == ">"
                position += 1
                continue
            }
            var name = String.UnicodeScalarView()
            while position < scalars.count {
                let current = scalars[position]
                if current == "=" || current == ">" || current == "/" || current.properties.isWhitespace { break }
                name.append(current)
                position += 1
            }
            if name.isEmpty {
                position += 1
                continue
            }
            skipWhitespace()
            var value = ""
            if position < scalars.count, scalars[position] == "=" {
                position += 1
                skipWhitespace()
                value = HTMLCharacterReferences.decode(readAttributeValue())
            }
            let key = String(name).lowercased()
            if attributes[key] == nil { attributes[key] = value }
        }
        return (attributes, isSelfClosed)
    }

    private mutating func readAttributeValue() -> String {
        guard position < scalars.count else { return "" }
        var value = String.UnicodeScalarView()
        let quote = scalars[position]
        if quote == "\"" || quote == "'" {
            position += 1
            while position < scalars.count, scalars[position] != quote {
                value.append(scalars[position])
                position += 1
            }
            position += 1
        } else {
            while position < scalars.count {
                let scalar = scalars[position]
                if scalar == ">" || scalar.properties.isWhitespace { break }
                value.append(scalar)
                position += 1
            }
        }
        return String(value)
    }

    private mutating func readRawText(until name: String) -> String {
        let closing = Array("</\(name)".unicodeScalars)
        let start = position
        while position < scalars.count {
            if scalars[position] == "<", position + closing.count <= scalars.count {
                var matches = true
                for (offset, expected) in closing.enumerated() {
                    let actual = scalars[position + offset]
                    if actual != expected, String(actual).lowercased() != String(expected) {
                        matches = false
                        break
                    }
                }
                if matches {
                    let raw = String(String.UnicodeScalarView(scalars[start..<position]))
                    position += closing.count
                    skip(past: ">")
                    return raw
                }
            }
            position += 1
        }
        return String(String.UnicodeScalarView(scalars[start..<position]))
    }

    private mutating func skipMarkupDeclaration() {
        // A comment ends at "-->", a doctype or CDATA section at the next ">".
        if position + 3 < scalars.count, scalars[position + 2] == "-", scalars[position + 3] == "-" {
            position += 4
            while position < scalars.count {
                if scalars[position] == "-", position + 2 < scalars.count, scalars[position + 1] == "-",
                    scalars[position + 2] == ">"
                {
                    position += 3
                    return
                }
                position += 1
            }
            return
        }
        skip(past: ">")
    }

    private mutating func skip(past terminator: Unicode.Scalar) {
        while position < scalars.count, scalars[position] != terminator { position += 1 }
        position += 1
    }
}

/// The decoding of HTML character references (`&amp;`, `&#x27;`, `&#39;`).
public enum HTMLCharacterReferences {
    /// `text` with its character references replaced by the characters they name. A reference the table does not know
    /// is kept as written.
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "&" else {
                result.append(scalar)
                index += 1
                continue
            }
            var end = index + 1
            while end < scalars.count, end - index <= 32, scalars[end] != ";", scalars[end] != "&",
                !scalars[end].properties.isWhitespace
            {
                end += 1
            }
            let body = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
            let hasSemicolon = end < scalars.count && scalars[end] == ";"
            if let decoded = decodeReference(body) {
                result.append(contentsOf: decoded.unicodeScalars)
                index = hasSemicolon ? end + 1 : end
            } else {
                result.append(scalar)
                index += 1
            }
        }
        return String(result)
    }

    private static func decodeReference(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value), value != 0 else { return value == nil ? nil : "\u{FFFD}" }
            return String(Character(scalar))
        }
        return namedReferences[body]
    }

    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{AD}",
        "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”",
        "bdquo": "„", "hellip": "…", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "micro": "µ", "para": "¶", "sect": "§",
        "laquo": "«", "raquo": "»", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "larr": "←",
        "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "le": "≤", "ge": "≥", "ne": "≠", "minus": "−",
        "infin": "∞", "check": "✓", "iexcl": "¡", "iquest": "¿", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "sup1": "¹", "sup2": "²", "sup3": "³", "acute": "´", "uml": "¨", "ordf": "ª", "ordm": "º", "not": "¬",
        "macr": "¯", "cedil": "¸", "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä",
        "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë",
        "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
        "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û",
        "Uuml": "Ü", "Yacute": "Ý", "szlig": "ß", "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã",
        "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê",
        "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "ntilde": "ñ", "ograve": "ò",
        "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù", "uacute": "ú",
        "ucirc": "û", "uuml": "ü", "yacute": "ý", "yuml": "ÿ",
    ]
}
