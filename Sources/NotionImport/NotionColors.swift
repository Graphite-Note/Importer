/**
 * File: NotionColors.swift
 * ------------------------
 * Layer: Notion
 * Description: Notion's colors as the vault writes them: a text color as a hex color in an HTML span, which
 *              Obsidian draws without a plugin, a background as a highlight, and a callout's background as the callout type of
 *              that color.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 28/11/2026
 */

import ImporterCore

/// Notion's nine colors, as text, backgrounds and callouts.
public enum NotionColors {
    /// Notion's text colors, between its light and dark ones, so that each reads on a light and a dark page.
    private static let textColors: [String: String] = [
        "gray": "#9b9a97", "brown": "#a27763", "orange": "#e07c3e", "yellow": "#d4a72c", "green": "#4f9768",
        "blue": "#3e89c9", "purple": "#9a6dd7", "pink": "#d15796", "red": "#e05a52", "teal": "#3f9f9a",
    ]

    /// The hex color of Notion's text color `name` (`red`), `nil` for the default color or a background.
    public static func textColor(named name: String) -> String? {
        textColors[name.lowercased()]
    }

    /// Notion's background colors as a CSS color that lets the text show through on a light and a dark page.
    private static let backgroundColors: [String: String] = [
        "gray": "rgba(155, 154, 151, 0.25)", "brown": "rgba(162, 119, 99, 0.25)", "orange": "rgba(224, 124, 62, 0.25)",
        "yellow": "rgba(212, 167, 44, 0.3)", "green": "rgba(79, 151, 104, 0.25)", "blue": "rgba(62, 137, 201, 0.25)",
        "purple": "rgba(154, 109, 215, 0.25)", "pink": "rgba(209, 87, 150, 0.25)", "red": "rgba(224, 90, 82, 0.25)",
        "teal": "rgba(63, 159, 154, 0.25)",
    ]

    /// The CSS color of Notion's background `name` (`red_background`), `nil` for the default.
    public static func backgroundColor(named name: String) -> String? {
        backgroundColors[name.lowercased().split(separator: "_").first.map(String.init) ?? ""]
    }

    /// `inlines` in the block color `color`: a text color as for text, a background as a mark in that color, as
    /// Notion draws a block's background behind its text.
    static func coloredBlock(_ inlines: [MarkdownInline], color: String) -> [MarkdownInline] {
        if color.hasSuffix("_background"), let css = backgroundColor(named: color) { return [.backgroundColor(css, inlines)] }
        return colored(inlines, color: color)
    }

    /// The callout type whose color is Notion's background `name` (`red_background`, or `red`), `nil` for gray and the
    /// default, where the callout's icon decides.
    public static func calloutType(forBackground name: String) -> String? {
        let color = name.lowercased().split(separator: "_").first.map(String.init) ?? ""
        let types: [String: String] = [
            "red": "danger", "pink": "danger", "orange": "warning", "yellow": "warning", "brown": "quote",
            "green": "success", "blue": "info", "purple": "example", "teal": "abstract",
        ]
        return types[color]
    }

    /// A Notion color name read from a class or attribute: `highlight-red` and `block-color-red` give `red`,
    /// `highlight-red_background` gives `red_background`. `nil` for the default color.
    static func colorName(fromClass name: String) -> String? {
        for prefix in ["highlight-", "block-color-", "select-value-color-"] where name.hasPrefix(prefix) {
            let color = String(name.dropFirst(prefix.count))
            return color == "default" || color == "default_background" || color.isEmpty ? nil : color
        }
        return nil
    }

    /// `inlines` in Notion's color `color`: a background as a highlight, a text color in its hex color, gray text as
    /// it is (Notion's gray is its secondary text, kept by its hex color too).
    static func colored(_ inlines: [MarkdownInline], color: String) -> [MarkdownInline] {
        if color.hasSuffix("_background") { return [.highlight(inlines)] }
        if let hex = textColor(named: color) { return [.textColor(hex, inlines)] }
        return inlines
    }
}
