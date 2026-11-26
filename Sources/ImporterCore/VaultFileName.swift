/**
 * File: VaultFileName.swift
 * -------------------------
 * Layer: Core
 * Description: Turns the title of an imported page into a file or folder name that every system a vault syncs to
 *              accepts and that Obsidian's links can point at.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

/// File and folder names made from the titles of imported pages.
///
/// A title can hold anything: a slash, a colon, an emoji, two hundred characters. The name made from it keeps as much
/// of the title as the vault allows. Characters that macOS, iOS, Windows or Android refuse, and the characters that
/// break an Obsidian link (`#`, `^`, `[`, `]`, `|`), become spaces. Control characters are dropped. Runs of spaces
/// become one. Leading dots are dropped, as a name starting with a dot is hidden. Trailing dots and spaces are dropped,
/// as Windows drops them. The name is cut, at a character boundary, to `maximumStemByteCount` bytes of UTF-8, so that
/// the extension and a number told apart from a second page of the same title still fit the 255 bytes file systems allow.
public enum VaultFileName {
    /// The name given to a page whose title leaves nothing once cleaned.
    public static let untitledStem = "Untitled"

    /// The most bytes of UTF-8 a name may have before its extension.
    public static let maximumStemByteCount = 200

    /// The characters replaced by a space: those a file system refuses and those that break an Obsidian link.
    public static let replacedCharacters: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "#", "^", "[", "]"]

    /// The name, without extension, of the file or folder made from `title`.
    public static func stem(forTitle title: String) -> String {
        var cleaned = ""
        var lastWasSpace = true
        for character in title {
            let isSpace = character.isWhitespace || replacedCharacters.contains(character)
            if !isSpace, character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                continue
            }
            if isSpace {
                if !lastWasSpace { cleaned.append(" ") }
            } else {
                cleaned.append(character)
            }
            lastWasSpace = isSpace
        }
        let withoutLeadingDots = cleaned.drop(while: { $0 == "." || $0 == " " })
        let cut = prefix(of: withoutLeadingDots, fittingByteCount: maximumStemByteCount)
        let withoutTrailingDots = cut.reversed().drop(while: { $0 == "." || $0 == " " }).reversed()
        let stem = String(withoutTrailingDots)
        return stem.isEmpty ? untitledStem : stem
    }

    /// The longest start of `text` whose UTF-8 takes at most `byteCount` bytes, never splitting a character.
    static func prefix(of text: Substring, fittingByteCount byteCount: Int) -> Substring {
        var usedByteCount = 0
        var end = text.startIndex
        for index in text.indices {
            let characterByteCount = text[index].utf8.count
            if usedByteCount + characterByteCount > byteCount { break }
            usedByteCount += characterByteCount
            end = text.index(after: index)
        }
        return text[text.startIndex..<end]
    }
}
