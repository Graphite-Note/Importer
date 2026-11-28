/**
 * File: MarkdownBlockLinks.swift
 * ------------------------------
 * Layer: Notion
 * Description: The wiki links of a note's blocks given new targets: the placeholders a page reader leaves for the files
 *              a page holds inside itself, replaced once the importer has placed those files.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 28/11/2026
 */

import ImporterCore

/// Wiki link targets replaced throughout a note's blocks.
enum MarkdownBlockLinks {
    /// `blocks` with each wiki link whose target `targets` names pointing at the target given for it.
    static func replacingTargets(in blocks: [MarkdownBlock], _ targets: [String: String]) -> [MarkdownBlock] {
        guard !targets.isEmpty else { return blocks }
        return blocks.map { block in replacingTargets(in: block, targets) }
    }

    private static func replacingTargets(in block: MarkdownBlock, _ targets: [String: String]) -> MarkdownBlock {
        func items(_ items: [MarkdownListItem]) -> [MarkdownListItem] {
            items.map { item in
                var item = item
                item.blocks = replacingTargets(in: item.blocks, targets)
                return item
            }
        }
        switch block {
        case .paragraph(let inlines):
            return .paragraph(replacingTargets(in: inlines, targets))
        case .heading(let level, let inlines):
            return .heading(level: level, replacingTargets(in: inlines, targets))
        case .bulletList(let list):
            return .bulletList(items(list))
        case .numberedList(let start, let list):
            return .numberedList(start: start, items(list))
        case .quote(let blocks):
            return .quote(replacingTargets(in: blocks, targets))
        case .callout(let type, let title, let folding, let body):
            return .callout(type: type, title: replacingTargets(in: title, targets), folding: folding,
                            body: replacingTargets(in: body, targets))
        case .table(let header, let rows):
            return .table(header: header.map { replacingTargets(in: $0, targets) },
                          rows: rows.map { row in row.map { replacingTargets(in: $0, targets) } })
        case .codeBlock, .mathBlock, .thematicBreak:
            return block
        }
    }

    private static func replacingTargets(in inlines: [MarkdownInline], _ targets: [String: String]) -> [MarkdownInline] {
        inlines.map { inline in
            switch inline {
            case .wikiLink(let target, let label, let isEmbed):
                return .wikiLink(target: targets[target] ?? target, label: label, isEmbed: isEmbed)
            case .strong(let children): return .strong(replacingTargets(in: children, targets))
            case .emphasis(let children): return .emphasis(replacingTargets(in: children, targets))
            case .strikethrough(let children): return .strikethrough(replacingTargets(in: children, targets))
            case .highlight(let children): return .highlight(replacingTargets(in: children, targets))
            case .underline(let children): return .underline(replacingTargets(in: children, targets))
            case .textColor(let color, let children): return .textColor(color, replacingTargets(in: children, targets))
            case .backgroundColor(let color, let children): return .backgroundColor(color, replacingTargets(in: children, targets))
            case .link(let destination, let label): return .link(destination: destination, label: replacingTargets(in: label, targets))
            default: return inline
            }
        }
    }
}
