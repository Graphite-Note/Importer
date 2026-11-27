/**
 * File: assemble-main.mjs
 * -----------------------
 * Layer: Build
 * Description: Writes the plugin's main.js: the WebAssembly module as base64, the import engine and the plugin, in
 *              one CommonJS file, as Obsidian and Graphite load a plugin.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 *
 * Usage: node assemble-main.mjs <importer.wasm> <main.js>
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const [modulePath, outputPath] = process.argv.slice(2);
const source = path.join(path.dirname(fileURLToPath(import.meta.url)), 'src');
const manifest = JSON.parse(fs.readFileSync(path.join(source, '..', '..', 'manifest.json'), 'utf8'));
const strict = /^'use strict';\n/m;
const engine = fs.readFileSync(path.join(source, 'importer-engine.js'), 'utf8').replace(strict, '');
const plugin = fs.readFileSync(path.join(source, 'plugin.js'), 'utf8').replace(strict, '');
const module = fs.readFileSync(modulePath).toString('base64');

const header = `/*
 * ${manifest.name} ${manifest.version}, built from https://github.com/Graphite-Note/Importer (Plugin/).
 * MIT License, Copyright (c) 2026 Bahey Shalash. Conversion rules ported from Obsidian Importer, Copyright (c) 2023
 * Obsidian, MIT License. The WebAssembly module below is the Importer's Swift code, built with the Swift SDK for
 * WebAssembly (Embedded Swift), whose runtime is Apache License 2.0 with Runtime Library Exception.
 */
'use strict';
`;
fs.writeFileSync(outputPath, header + `const IMPORTER_MODULE_BASE64 = '${module}';\n` + engine + plugin);
