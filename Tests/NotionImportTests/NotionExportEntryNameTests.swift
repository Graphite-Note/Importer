/**
 * File: NotionExportEntryNameTests.swift
 * --------------------------------------
 * Layer: Tests
 * Description: The names of the files and folders of Notion's HTML export, read into title and page identifier.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Testing

@testable import NotionImport

struct NotionExportEntryNameTests {
    @Test func aPageFileGivesItsTitleIdentifierAndExtension() throws {
        let name = try #require(NotionExportEntryName("Week 1 3F2A9C4E1B7D4E0F8A6B5C4D3E2F1A0B.html"))
        #expect(name.title == "Week 1")
        #expect(name.pageIdentifier == "3f2a9c4e-1b7d-4e0f-8a6b-5c4d3e2f1a0b")
        #expect(name.pathExtension == "html")
        #expect(!name.isAllRowsTable)
    }

    @Test func aFolderOfSubpagesHasNoExtension() throws {
        let name = try #require(NotionExportEntryName("Signals and Systems 0123456789abcdef0123456789abcdef"))
        #expect(name.title == "Signals and Systems")
        #expect(name.pathExtension == nil)
    }

    @Test func aDatabasesTablesAreTold() throws {
        let rows = try #require(NotionExportEntryName("Assignments 0123456789abcdef0123456789abcdef.csv"))
        #expect(!rows.isAllRowsTable)
        let allRows = try #require(NotionExportEntryName("Assignments 0123456789abcdef0123456789abcdef_all.csv"))
        #expect(allRows.isAllRowsTable)
        #expect(allRows.title == "Assignments")
    }

    @Test func aTitleWithDotsKeepsThem() throws {
        let name = try #require(NotionExportEntryName("v1.2 notes 0123456789abcdef0123456789abcdef"))
        #expect(name.title == "v1.2 notes")
        #expect(name.pathExtension == nil)
    }

    @Test func namesWithoutAnIdentifierAreRefused() {
        #expect(NotionExportEntryName("Week 1.html") == nil)
        #expect(NotionExportEntryName("Week 10123456789abcdef0123456789abcdef.html") == nil)
        #expect(NotionExportEntryName("Week 1 0123456789abcdef0123456789abcdeg.html") == nil)
    }
}
