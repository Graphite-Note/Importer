/**
 * File: NotionAPIBaseWriter.swift
 * -------------------------------
 * Layer: Notion
 * Description: A Notion database read through the API, written as an Obsidian base: its formulas and rollups Bases can compute,
 *              and its table, board, gallery and list views as Bases table, Kanban, cards and list views with the
 *              properties they show, their groups, sorts and filters where Bases can express them.
 *
 * Authors: Bahey Shalash
 * Version: 0.3
 * Date: 27/11/2026
 */

import ImporterCore

/// Writes a database's base.
enum NotionAPIBaseWriter {
    /// The base of `database`, whose data source `dataSource` has the properties `schema`, with `views` as the views
    /// endpoint gives them, over the notes of `rowsFolder`. `formulas` are the converted formulas, by name. With
    /// `showsTitles` (some row's note is not named by its whole title) the rows' names are their titles
    /// (`NotionDatabaseTable.titleFormula`).
    static func base(for database: JSONValue, schema: JSONValue, views: [JSONValue], dataSource: String, rowsFolder: VaultPath,
                     formulas: [String: String], showsTitles: Bool = false) -> (file: BaseFile, findings: [NotionPageFinding]) {
        var findings: [NotionPageFinding] = []
        func note(_ severity: ImportReport.Severity, _ message: String) {
            let finding = NotionPageFinding(severity: severity, message: message)
            if !findings.contains(finding) { findings.append(finding) }
        }
        var names: [String: String] = [:]
        var titleName = "Name"
        var displayNames: [(property: String, displayName: String)] = []
        var allColumns = ["file.name"]
        for (name, property) in schema.members {
            if let identifier = property["id"]?.string { names[identifier] = name }
            switch property["type"]?.string {
            case "title":
                titleName = name
            case "formula", "rollup":
                if formulas[name] != nil {
                    allColumns.append("formula." + name)
                } else {
                    // A rollup's reason is reported where it is converted.
                    if property["type"]?.string == "formula" {
                        note(.simplified, "the formula “\(name)” uses what Bases cannot compute, so each note holds its value when imported")
                    }
                    allColumns.append(column(for: name, type: "formula"))
                }
            case "button":
                continue
            default:
                allColumns.append(column(for: name, type: property["type"]?.string ?? ""))
            }
        }
        displayNames.append(("file.name", titleName))
        // Formulas after the properties, as Notion lists them last.
        allColumns = allColumns.filter { !$0.hasPrefix("formula.") } + allColumns.filter { $0.hasPrefix("formula.") }

        var baseViews: [BaseFile.View] = []
        let plainSource = NotionAPIPageReader.plainIdentifier(dataSource)
        for view in views {
            let configuration = view["configuration"] ?? .null
            let name = view["name"]?.string ?? "View"
            if let source = view["data_source_id"]?.string, NotionAPIPageReader.plainIdentifier(source) != plainSource {
                note(.leftOut, "the view “\(name)” shows another data source of the database and was left out")
                continue
            }
            var visible: [String] = []
            for shown in configuration["properties"]?.elements ?? [] where shown["visible"]?.bool != false {
                let propertyName = shown["property_name"]?.string ?? shown["property_id"]?.string.flatMap { names[$0] } ?? ""
                guard !propertyName.isEmpty, propertyName != titleName, let type = schema[propertyName]?["type"]?.string else { continue }
                visible.append(formulas[propertyName] != nil && isComputed(type) ? "formula." + propertyName : column(for: propertyName, type: type))
            }
            var baseView: BaseFile.View
            switch view["type"]?.string ?? configuration["type"]?.string ?? "table" {
            case "table":
                baseView = BaseFile.View(type: "table", name: name, order: configuration["properties"] == nil ? allColumns : ["file.name"] + visible)
            case "board":
                baseView = BaseFile.View(type: "kanban", name: name, order: ["file.name"] + visible)
                let groupBy = configuration["group_by"] ?? .null
                if let property = groupBy["property_name"]?.string ?? groupBy["property_id"]?.string.flatMap({ names[$0] }) {
                    let type = schema[property]?["type"]?.string ?? ""
                    let isFormula = isComputed(type) && formulas[property] != nil
                    let sort = groupBy["sort"]?["type"]?.string ?? groupBy["group_by"]?["sort"]?["type"]?.string
                    baseView.groupBy = (isFormula ? "formula." + property : "note." + column(for: property, type: type), sort == "descending" ? "DESC" : "ASC")
                    if sort == "manual" || sort == nil, type == "select" || type == "status" {
                        // Notion's own order of the columns, the notes without a value first.
                        baseView.groupOrder = [""] + (schema[property]?[type]?["options"]?.elements ?? []).compactMap { $0["name"]?.string }
                    }
                }
            case "gallery":
                baseView = BaseFile.View(type: "cards", name: name, order: ["file.name"] + visible)
            case "list":
                baseView = BaseFile.View(type: "list", name: name, order: ["file.name"] + visible)
            default:
                let type = view["type"]?.string ?? "unknown"
                note(.simplified, "the \(type) view “\(name)” has no counterpart in Bases and became a table view")
                baseView = BaseFile.View(type: "table", name: name, order: allColumns)
            }
            if let cover = configuration["cover"] {
                switch cover["type"]?.string {
                case "page_cover": baseView.image = "note.banner"
                case "property":
                    if let property = cover["property_id"]?.string.flatMap({ names[$0] }) ?? cover["property_name"]?.string { baseView.image = "note." + property }
                default: break
                }
                if let aspect = configuration["cover_aspect"]?.string { baseView.imageFit = aspect == "contain" ? "contain" : "cover" }
            }
            for sort in configuration["sorts"]?.elements ?? [] {
                guard let property = sort["property"]?.string ?? sort["property_name"]?.string else {
                    note(.leftOut, "a sort of the view “\(name)” by a time the notes do not hold was left out")
                    continue
                }
                let type = schema[property]?["type"]?.string ?? ""
                let sorted = type == "title" ? "file.name"
                    : isComputed(type) && formulas[property] != nil ? "formula." + property : "note." + column(for: property, type: type)
                baseView.sort.append((sorted, sort["direction"]?.string == "descending" ? "DESC" : "ASC"))
            }
            if let filter = configuration["filter"] {
                if let expression = filterExpression(filter, schema: schema) {
                    baseView.filters.append(expression)
                } else {
                    note(.leftOut, "the filter of the view “\(name)” uses conditions Bases cannot express and was left out")
                }
            }
            baseViews.append(baseView)
        }
        if baseViews.isEmpty {
            // No view the integration can read: one table view, named after the database as Notion shows its title.
            let title = NotionAPIPropertyReader.plainText(database["title"] ?? .null)
            baseViews.append(BaseFile.View(type: "table", name: title.isEmpty ? "Table" : title, order: allColumns))
        }
        var sortedFormulas = formulas.sorted { $0.key < $1.key }.map { (name: $0.key, expression: $0.value) }
        // Rows whose notes are not named by their whole titles show them, each a link to its note.
        let titleFormula = NotionDatabaseTable.titleFormula
        if showsTitles, formulas[titleFormula.name] == nil {
            let nameKey = "formula." + titleFormula.name
            for index in baseViews.indices {
                baseViews[index].order = baseViews[index].order.map { $0 == "file.name" ? nameKey : $0 }
            }
            displayNames = displayNames.map { $0.property == "file.name" ? (nameKey, $0.displayName) : $0 }
            sortedFormulas.insert(titleFormula, at: 0)
        }
        return (BaseFile(folder: rowsFolder, displayNames: displayNames, views: baseViews, formulas: sortedFormulas), findings)
    }

    /// Whether a property of `type` is computed: a formula or a rollup, which the base computes when it can.
    static func isComputed(_ type: String) -> Bool {
        type == "formula" || type == "rollup"
    }

    /// The property a column shows: `tags` for a multi-select called Tags, as the notes name it.
    static func column(for name: String, type: String) -> String {
        type == "multi_select" && name.lowercased() == "tags" ? "tags" : name
    }

    /// A view's filter, in the shape of a data source query's filter, as a Bases expression: `and` and `or` of
    /// conditions on one property each. `nil` when one condition has no counterpart.
    static func filterExpression(_ filter: JSONValue, schema: JSONValue) -> String? {
        for (combiner, symbol) in [("and", " && "), ("or", " || ")] {
            if let parts = filter[combiner]?.elements {
                let expressions = parts.map { filterExpression($0, schema: schema) }
                guard !expressions.contains(where: { $0 == nil }) else { return nil }
                let joined = expressions.compactMap { $0 }
                return joined.count == 1 ? joined[0] : "(" + joined.joined(separator: symbol) + ")"
            }
        }
        guard let property = filter["property"]?.string, let type = schema[property]?["type"]?.string else { return nil }
        let reference = type == "title" ? "file.name" : "note[\"" + column(for: property, type: type).replacingEvery("\"", with: "\\\"") + "\"]"
        guard let condition = (filter[type] ?? filter["rich_text"] ?? filter["select"])?.members.first else { return nil }
        func literal(_ value: JSONValue) -> String? {
            switch value {
            case .string(let text): return "\"" + text.replacingEvery("\\", with: "\\\\").replacingEvery("\"", with: "\\\"") + "\""
            case .number(let text): return text
            case .bool(let flag): return flag ? "true" : "false"
            default: return nil
            }
        }
        switch condition.key {
        case "equals": return literal(condition.value).map { reference + " == " + $0 }
        case "does_not_equal": return literal(condition.value).map { reference + " != " + $0 }
        case "contains": return literal(condition.value).map { reference + ".contains(" + $0 + ")" }
        case "does_not_contain": return literal(condition.value).map { "!" + reference + ".contains(" + $0 + ")" }
        case "starts_with": return literal(condition.value).map { reference + ".startsWith(" + $0 + ")" }
        case "ends_with": return literal(condition.value).map { reference + ".endsWith(" + $0 + ")" }
        case "is_empty": return reference + ".isEmpty()"
        case "is_not_empty": return "!" + reference + ".isEmpty()"
        case "greater_than": return literal(condition.value).map { reference + " > " + $0 }
        case "less_than": return literal(condition.value).map { reference + " < " + $0 }
        case "greater_than_or_equal_to": return literal(condition.value).map { reference + " >= " + $0 }
        case "less_than_or_equal_to": return literal(condition.value).map { reference + " <= " + $0 }
        case "before": return literal(condition.value).map { reference + " < date(" + $0 + ")" }
        case "after": return literal(condition.value).map { reference + " > date(" + $0 + ")" }
        case "on_or_before": return literal(condition.value).map { reference + " <= date(" + $0 + ")" }
        case "on_or_after": return literal(condition.value).map { reference + " >= date(" + $0 + ")" }
        default: return nil
        }
    }
}
