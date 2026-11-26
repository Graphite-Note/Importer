/**
 * File: BaseFile.swift
 * --------------------
 * Layer: Core
 * Description: An Obsidian Base (a `.base` file): the notes of one folder shown as a database, with the properties
 *              it names and its views, written as the YAML Obsidian and Graphite read.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

import Foundation

/// A base showing the notes of one folder.
public struct BaseFile: Equatable, Sendable {
    /// A view of the base.
    public struct View: Equatable, Sendable {
        /// The view's kind: `table`, `cards`, `list`.
        public var type: String
        /// The view's name.
        public var name: String
        /// The columns shown, in order: `file.name` for the note's name, else property names.
        public var order: [String]

        public init(type: String, name: String, order: [String]) {
            self.type = type
            self.name = name
            self.order = order
        }
    }

    /// The vault path of the folder whose notes the base shows (its notes only, not those of folders inside it).
    public var folder: VaultPath
    /// The name shown for each column, by property name (`file.name` for the note's name).
    public var displayNames: [(property: String, displayName: String)]
    /// The views.
    public var views: [View]

    public init(folder: VaultPath, displayNames: [(property: String, displayName: String)], views: [View]) {
        self.folder = folder
        self.displayNames = displayNames
        self.views = views
    }

    public static func == (left: BaseFile, right: BaseFile) -> Bool {
        left.folder == right.folder && left.views == right.views && left.displayNames.count == right.displayNames.count
            && zip(left.displayNames, right.displayNames).allSatisfy { $0.property == $1.property && $0.displayName == $1.displayName }
    }

    /// The `.base` file's YAML.
    public var yaml: String {
        var lines: [String] = []
        let folderPath = folder.description.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        lines.append("filters: " + YAMLScalar.quotedIfNeeded("file.folder == \"\(folderPath)\""))
        if !displayNames.isEmpty {
            lines.append("properties:")
            for (property, displayName) in displayNames {
                lines.append("  \(YAMLScalar.quotedIfNeeded(property)):")
                lines.append("    displayName: \(YAMLScalar.quotedIfNeeded(displayName))")
            }
        }
        lines.append("views:")
        for view in views {
            lines.append("  - type: \(YAMLScalar.quotedIfNeeded(view.type))")
            lines.append("    name: \(YAMLScalar.quotedIfNeeded(view.name))")
            if !view.order.isEmpty {
                lines.append("    order:")
                lines.append(contentsOf: view.order.map { "      - \(YAMLScalar.quotedIfNeeded($0))" })
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
