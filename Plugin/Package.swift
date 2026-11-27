// swift-tools-version: 6.2
/**
 * File: Package.swift
 * -------------------
 * Layer: Build
 * Description: The WebAssembly module of the Notion importer plugin: the Importer's library targets with the calls a
 *              JavaScript plugin makes, built with the Swift SDK for WebAssembly only. A package of its own, so the
 *              Importer that apps link has no executable for WebAssembly and no experimental feature.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */
import PackageDescription

let package = Package(
    name: "ImporterPlugin",
    products: [
        .executable(name: "ImporterWasm", targets: ["ImporterWasm"])
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        // Built as a WASI reactor (`-Xclang-linker -mexec-model=reactor`, given by build-plugin.sh): the plugin calls
        // `_initialize` once, then the exports.
        .executableTarget(
            name: "ImporterWasm",
            dependencies: [.product(name: "PortableImporter", package: "Importer")],
            swiftSettings: [.enableExperimentalFeature("Extern"), .treatAllWarnings(as: .error)])
    ]
)
