/**
 * File: VaultPathAndDestinationTests.swift
 * ----------------------------------------
 * Layer: Tests
 * Description: Vault paths refuse names that climb out of the vault, and a folder destination writes new files and
 *              never replaces one.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation
import Testing

@testable import ImporterCore

struct VaultPathAndDestinationTests {
    @Test func namesThatLeaveTheirFolderAreRefused() {
        #expect(VaultPath(components: ["..", "Library"]) == nil)
        #expect(VaultPath(components: ["Notes", "a/b"]) == nil)
        #expect(VaultPath(components: ["Notes", "a\\b"]) == nil)
        #expect(VaultPath(components: ["Notes", ""]) == nil)
        #expect(VaultPath(components: ["."]) == nil)
        #expect(VaultPath.vaultFolder.appending("..") == nil)
        #expect(VaultPath(components: ["Notion", "Week 1.md"])?.description == "Notion/Week 1.md")
    }

    @Test func aPathKnowsItsFolderAndName() throws {
        let path = try #require(VaultPath(components: ["Notion", "Course", "Week 1.md"]))
        #expect(path.name == "Week 1.md")
        #expect(path.parent?.description == "Notion/Course")
        #expect(VaultPath.vaultFolder.parent == nil)
    }

    @Test func aFolderDestinationWritesNewFilesAndNeverReplacesOne() async throws {
        let vaultFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: vaultFolder) }
        let destination = FolderImportDestination(vaultFolder: vaultFolder)
        let folder = try #require(VaultPath(components: ["Notion", "Course"]))
        let note = try #require(folder.appending("Week 1.md"))

        try await destination.createFolder(at: folder)
        try await destination.writeNewFile(Data("# Week 1\n".utf8), at: note)
        #expect(try await destination.names(inFolderAt: folder) == ["Week 1.md"])

        await #expect(throws: ImportDestinationError.fileAlreadyExists(note)) {
            try await destination.writeNewFile(Data("replaced".utf8), at: note)
        }
        let written = try String(contentsOf: vaultFolder.appendingPathComponent("Notion/Course/Week 1.md"), encoding: .utf8)
        #expect(written == "# Week 1\n")
        #expect(try await destination.names(inFolderAt: try #require(VaultPath(components: ["Missing"]))).isEmpty)
    }
}
