/**
 * File: VaultFolderNames.swift
 * ----------------------------
 * Layer: Core
 * Description: The names already given in one folder of an import, so that two pages of the same title become
 *              "Title.md" and "Title 2.md" instead of one overwriting the other.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

/// The names taken in one folder of an import.
///
/// Names are compared as the file systems a vault lives on compare them: without regard to case, and with
/// canonically equivalent spellings of the same text (an "é" as one character or as "e" and an accent) taken as equal,
/// which is how Swift compares strings. A name is claimed with its extension, so the note "Week 1.md" and the folder
/// "Week 1" of its subpages can sit side by side, as Obsidian's Importer and Notion's export place them.
public struct VaultFolderNames: Sendable {
    private var takenNames: Set<String>

    /// A folder holding the names `existingNames` already, such as the files found in it before the import.
    public init(existingNames: some Sequence<String> = []) {
        takenNames = Set(existingNames.map { $0.lowercased() })
    }

    /// Takes the first free name of `stem`, `stem 2`, `stem 3` and so on, followed by `.pathExtension` when an extension
    /// is given, and returns it.
    public mutating func claim(stem: String, pathExtension: String? = nil) -> String {
        var number = 1
        while true {
            let numberedStem = number == 1 ? stem : "\(stem) \(number)"
            let name = pathExtension.map { "\(numberedStem).\($0)" } ?? numberedStem
            if takenNames.insert(name.lowercased()).inserted {
                return name
            }
            number += 1
        }
    }

    /// Whether `name`, extension included, is taken.
    public func isTaken(_ name: String) -> Bool {
        takenNames.contains(name.lowercased())
    }
}
