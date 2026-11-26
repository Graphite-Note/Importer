/**
 * File: VaultPath.swift
 * ---------------------
 * Layer: Core
 * Description: A path inside the vault an import writes to, made of names checked never to climb out of the vault.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

/// A file or folder inside the vault, relative to the vault's folder.
///
/// An export is read from outside: a crafted export could name a page "../../Library" to write outside the vault.
/// A vault path is made only of names that are not empty, not "." or "..", and hold no "/" or "\", so whatever an
/// import writes stays in the vault.
public struct VaultPath: Hashable, Sendable, CustomStringConvertible {
    /// The names from the vault's folder down to the file or folder, the vault's folder itself being no name at all.
    public let components: [String]

    /// The vault's own folder.
    public static let vaultFolder = VaultPath(checkedComponents: [])

    /// The path of `components`, or `nil` when one of them is not a single name inside its folder.
    public init?(components: [String]) {
        guard components.allSatisfy(VaultPath.isSingleName) else { return nil }
        self.components = components
    }

    private init(checkedComponents: [String]) {
        components = checkedComponents
    }

    /// The path of `name` inside this folder, or `nil` when `name` is not a single name.
    public func appending(_ name: String) -> VaultPath? {
        guard VaultPath.isSingleName(name) else { return nil }
        return VaultPath(checkedComponents: components + [name])
    }

    /// The folder this file or folder is in, `nil` for the vault's own folder.
    public var parent: VaultPath? {
        components.isEmpty ? nil : VaultPath(checkedComponents: Array(components.dropLast()))
    }

    /// The last name, empty for the vault's own folder.
    public var name: String {
        components.last ?? ""
    }

    /// The path written with "/" between its names, as Obsidian writes vault paths.
    public var description: String {
        components.joined(separator: "/")
    }

    private static func isSingleName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains("\u{0}")
    }
}
