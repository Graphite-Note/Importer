/**
 * File: import-with-plugin.cjs
 * ----------------------------
 * Layer: Tests
 * Description: Imports Notion exports into a vault folder with the plugin's engine and module, as the plugin does in
 *              a web view, and prints the import's summary as JSON.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 *
 * Usage: node import-with-plugin.cjs <importer.wasm> <vault folder> <into folder> <date> <year> <export.zip>…
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { NotionImportEngine } = require('../src/importer-engine.js');
const { FolderVault } = require('./folder-vault.cjs');

async function main() {
    const [modulePath, vaultFolder, into, date, year, ...exports] = process.argv.slice(2);
    const files = exports.map((file) => new File([fs.readFileSync(file)], path.basename(file)));
    const vault = new FolderVault(vaultFolder);
    const engine = new NotionImportEngine(fs.readFileSync(modulePath), vault);
    let progressCalls = 0;
    const summary = await engine.importNotionExport({
        files, folder: into, date, exportYear: Number(year), onProgress: () => { progressCalls += 1; },
    });
    summary.progressCalls = progressCalls;
    summary.peakMemoryMB = Math.round(engine.instance.exports.memory.buffer.byteLength / 1048576);
    console.log(JSON.stringify(summary));
}

main().catch((error) => {
    console.error(error.message);
    process.exit(1);
});
