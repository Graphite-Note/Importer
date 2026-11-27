/**
 * File: BaseFile.swift
 * --------------------
 * Layer: Core
 * Description: An Obsidian Base (a `.base` file): the notes of one folder shown as a database, with the properties
 *              it names and its views, written as the YAML Obsidian and Graphite read.
 *
 * Authors: Bahey Shalash
 * Version: 0.3
 * Date: 27/11/2026
 */

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
        /// The property a Kanban view puts its columns by, `note.Status` or `formula.State`, and the order of the
        /// columns: ascending or descending, or the values in the order given (`groupOrder`).
        public var groupBy: (property: String, direction: String)?
        public var groupOrder: [String]
        /// The sort, each key a property and `ASC` or `DESC`.
        public var sort: [(property: String, direction: String)]
        /// The view's own filters, as Bases expressions all of which must hold.
        public var filters: [String]
        /// The property a card shows as its picture, and how it fits (`cover`, `contain`).
        public var image: String?
        public var imageFit: String?

        public init(type: String, name: String, order: [String], groupBy: (property: String, direction: String)? = nil, groupOrder: [String] = [],
                    sort: [(property: String, direction: String)] = [], filters: [String] = [], image: String? = nil, imageFit: String? = nil) {
            self.type = type
            self.name = name
            self.order = order
            self.groupBy = groupBy
            self.groupOrder = groupOrder
            self.sort = sort
            self.filters = filters
            self.image = image
            self.imageFit = imageFit
        }

        public static func == (left: View, right: View) -> Bool {
            left.type == right.type && left.name == right.name && left.order == right.order
                && left.groupBy?.property == right.groupBy?.property && left.groupBy?.direction == right.groupBy?.direction
                && left.groupOrder == right.groupOrder && left.filters == right.filters && left.image == right.image && left.imageFit == right.imageFit
                && left.sort.count == right.sort.count
                && zip(left.sort, right.sort).allSatisfy { $0.property == $1.property && $0.direction == $1.direction }
        }
    }

    /// The vault path of the folder whose notes the base shows (its notes only, not those of folders inside it).
    public var folder: VaultPath
    /// The name shown for each column, by property name (`file.name` for the note's name).
    public var displayNames: [(property: String, displayName: String)]
    /// The views.
    public var views: [View]
    /// Formulas the views can show as `formula.<name>`, by name, in Bases' formula language.
    public var formulas: [(name: String, expression: String)]

    public init(folder: VaultPath, displayNames: [(property: String, displayName: String)], views: [View],
                formulas: [(name: String, expression: String)] = []) {
        self.folder = folder
        self.displayNames = displayNames
        self.views = views
        self.formulas = formulas
    }

    public static func == (left: BaseFile, right: BaseFile) -> Bool {
        left.folder == right.folder && left.views == right.views && left.displayNames.count == right.displayNames.count
            && left.formulas.count == right.formulas.count
            && zip(left.formulas, right.formulas).allSatisfy { $0.name == $1.name && $0.expression == $1.expression }
            && zip(left.displayNames, right.displayNames).allSatisfy { $0.property == $1.property && $0.displayName == $1.displayName }
    }

    /// The `.base` file's YAML.
    public var yaml: String {
        var lines: [String] = []
        let folderPath = folder.description.replacingEvery("\\", with: "\\\\").replacingEvery("\"", with: "\\\"")
        lines.append("filters: " + YAMLScalar.quotedIfNeeded("file.folder == \"\(folderPath)\""))
        if !formulas.isEmpty {
            lines.append("formulas:")
            for (name, expression) in formulas {
                lines.append("  \(YAMLScalar.quotedIfNeeded(name)): \(YAMLScalar.quotedIfNeeded(expression))")
            }
        }
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
            if !view.filters.isEmpty {
                lines.append("    filters:")
                lines.append("      and:")
                lines.append(contentsOf: view.filters.map { "        - \(YAMLScalar.quotedIfNeeded($0))" })
            }
            if let groupBy = view.groupBy {
                lines.append("    groupBy:")
                lines.append("      property: \(YAMLScalar.quotedIfNeeded(groupBy.property))")
                lines.append("      direction: \(groupBy.direction)")
            }
            if !view.groupOrder.isEmpty {
                lines.append("    groupOrder:")
                lines.append(contentsOf: view.groupOrder.map { "      - \(YAMLScalar.quotedIfNeeded($0))" })
            }
            if !view.order.isEmpty {
                lines.append("    order:")
                lines.append(contentsOf: view.order.map { "      - \(YAMLScalar.quotedIfNeeded($0))" })
            }
            if !view.sort.isEmpty {
                lines.append("    sort:")
                for key in view.sort {
                    lines.append("      - property: \(YAMLScalar.quotedIfNeeded(key.property))")
                    lines.append("        direction: \(key.direction)")
                }
            }
            if let image = view.image { lines.append("    image: \(YAMLScalar.quotedIfNeeded(image))") }
            if let imageFit = view.imageFit { lines.append("    imageFit: \(imageFit)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
