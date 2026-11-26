/**
 * File: VaultFileNameTests.swift
 * ------------------------------
 * Layer: Tests
 * Description: The names made from page titles: what is replaced, what is dropped, how long names are cut, and how a
 *              folder tells apart two pages of the same title.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Testing

@testable import ImporterCore

struct VaultFileNameTests {
    @Test func charactersFileSystemsOrLinksRefuseBecomeOneSpace() {
        #expect(VaultFileName.stem(forTitle: "Signals: week 1/2") == "Signals week 1 2")
        #expect(VaultFileName.stem(forTitle: "A [draft] #3 | v^2") == "A draft 3 v 2")
        #expect(VaultFileName.stem(forTitle: "What? \"Why\" <now> *") == "What Why now")
    }

    @Test func controlCharactersAreDroppedAndSpacesCollapsed() {
        #expect(VaultFileName.stem(forTitle: "Tab\there\u{7}  and\n\nthere") == "Tab here and there")
    }

    @Test func leadingAndTrailingDotsAndSpacesAreDropped() {
        #expect(VaultFileName.stem(forTitle: "..hidden") == "hidden")
        #expect(VaultFileName.stem(forTitle: "  Notes...  ") == "Notes")
    }

    @Test func emojiAndAccentsAreKept() {
        #expect(VaultFileName.stem(forTitle: "📚 Résumé") == "📚 Résumé")
    }

    @Test func aTitleThatLeavesNothingIsUntitled() {
        #expect(VaultFileName.stem(forTitle: "") == "Untitled")
        #expect(VaultFileName.stem(forTitle: "/// ...") == "Untitled")
    }

    @Test func longTitlesAreCutAtACharacterBoundaryWithinTheByteLimit() {
        let title = String(repeating: "é", count: 150)
        let stem = VaultFileName.stem(forTitle: title)
        #expect(stem.utf8.count <= VaultFileName.maximumStemByteCount)
        #expect(stem == String(repeating: "é", count: 100))
        let emojiStem = VaultFileName.stem(forTitle: String(repeating: "👩‍👩‍👧", count: 20))
        #expect(emojiStem.utf8.count <= VaultFileName.maximumStemByteCount)
        #expect(emojiStem.allSatisfy { $0 == "👩‍👩‍👧" })
    }

    @Test func pagesOfTheSameTitleGetNumberedNames() {
        var names = VaultFolderNames()
        #expect(names.claim(stem: "Week 1", pathExtension: "md") == "Week 1.md")
        #expect(names.claim(stem: "Week 1", pathExtension: "md") == "Week 1 2.md")
        #expect(names.claim(stem: "week 1", pathExtension: "md") == "week 1 3.md")
        #expect(names.claim(stem: "Week 1") == "Week 1")
    }

    @Test func namesAlreadyInTheFolderAreNotTakenAgain() {
        var names = VaultFolderNames(existingNames: ["Résumé.md"])
        #expect(names.claim(stem: "Re\u{301}sume\u{301}", pathExtension: "md") == "Re\u{301}sume\u{301} 2.md")
        #expect(names.isTaken("résumé.MD"))
    }
}
