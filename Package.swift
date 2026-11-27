// swift-tools-version: 6.2
/**
 * File: Package.swift
 * -------------------
 * Layer: Build
 * Description: The standalone package that turns other note apps' exports into ordinary vault files (Markdown notes,
 *              Obsidian Bases and attachments), starting with Notion; a warning in any of its targets fails the build.
 *
 * Authors: Bahey Shalash
 * Version: 0.3
 * Date: 27/11/2026
 */
import PackageDescription

// Reads an export and writes the vault files it becomes. It knows no app: the host hands it the export to read, the
// place to write and, for an import over the network, the way to send a request. ImporterCore and NotionImport use the
// Swift standard library alone, no Foundation, so that the same code runs as a downloadable plugin compiled to
// WebAssembly with a small module. Files on disk are read and written by ImporterFileSystem, which uses Foundation and
// which only hosts that link the package use.
let package = Package(
    name: "Importer",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Importer", targets: ["ImporterCore", "NotionImport", "ImporterFileSystem"]),
        // The importers alone, without the file system and so without Foundation: what the WebAssembly plugin links.
        .library(name: "PortableImporter", targets: ["ImporterCore", "NotionImport"]),
        .executable(name: "importer", targets: ["ImporterCommand"])
    ],
    targets: [
        // What every format shares: vault file names, the place imported files are written to, the import report.
        .target(name: "ImporterCore"),
        // Notion's HTML export and Notion's API.
        .target(name: "NotionImport", dependencies: ["ImporterCore"]),
        // A folder on disk as the source, the destination and the temporary storage, with Foundation.
        .target(name: "ImporterFileSystem", dependencies: ["ImporterCore"]),
        // The `importer` command, for manual runs on real exports.
        .executableTarget(name: "ImporterCommand", dependencies: ["ImporterCore", "NotionImport", "ImporterFileSystem"]),
        // Zip archives written by the tests and the place of the committed test material.
        .target(name: "ImporterTestSupport", dependencies: ["ImporterCore", "ImporterFileSystem"], path: "Tests/ImporterTestSupport"),
        .testTarget(name: "ImporterCoreTests", dependencies: ["ImporterCore", "ImporterFileSystem", "ImporterTestSupport"]),
        .testTarget(name: "NotionImportTests", dependencies: ["NotionImport", "ImporterFileSystem", "ImporterTestSupport"])
    ]
)

// The package builds with no warning: a warning in any of its targets fails the build.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
