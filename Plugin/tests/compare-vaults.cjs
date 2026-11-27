/**
 * File: compare-vaults.cjs
 * ------------------------
 * Layer: Tests
 * Description: Compares two vault folders file by file, byte by byte. Paths are compared in Unicode's composed form,
 *              since Foundation writes names decomposed on macOS and Node as given, and types.json as JSON, whose key
 *              order each host chooses.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 *
 * Usage: node compare-vaults.cjs <vault> <other vault>. Prints the number of files, or the differences and exits 1.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

function files(folder) {
    const found = new Map();
    const walk = (current, relative) => {
        for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
            const entryRelative = relative === '' ? entry.name : relative + '/' + entry.name;
            if (entry.isDirectory()) walk(path.join(current, entry.name), entryRelative);
            else found.set(entryRelative.normalize('NFC'), path.join(current, entry.name));
        }
    };
    walk(folder, '');
    return found;
}

function sortedJSON(value) {
    if (Array.isArray(value)) return value.map(sortedJSON);
    if (value === null || typeof value !== 'object') return value;
    const sorted = {};
    for (const key of Object.keys(value).sort()) sorted[key] = sortedJSON(value[key]);
    return sorted;
}

const [first, second] = process.argv.slice(2);
const firstFiles = files(first);
const secondFiles = files(second);
const differences = [];
for (const name of firstFiles.keys()) if (!secondFiles.has(name)) differences.push('only in the first: ' + name);
for (const name of secondFiles.keys()) if (!firstFiles.has(name)) differences.push('only in the second: ' + name);
for (const [name, file] of firstFiles) {
    const other = secondFiles.get(name);
    if (!other) continue;
    const a = fs.readFileSync(file);
    const b = fs.readFileSync(other);
    if (name.endsWith('/types.json') || name === 'types.json') {
        const same = JSON.stringify(sortedJSON(JSON.parse(a.toString('utf8')))) === JSON.stringify(sortedJSON(JSON.parse(b.toString('utf8'))));
        if (!same) differences.push('types differ: ' + name);
    } else if (!a.equals(b)) {
        differences.push('bytes differ: ' + name);
    }
}
if (differences.length > 0) {
    console.log(differences.slice(0, 40).join('\n'));
    if (differences.length > 40) console.log('… and ' + (differences.length - 40) + ' more');
    process.exit(1);
}
console.log(String(firstFiles.size));
