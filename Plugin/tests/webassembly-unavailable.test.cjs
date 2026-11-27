/**
 * File: webassembly-unavailable.test.cjs
 * --------------------------------------
 * Layer: Tests
 * Description: The plugin where its web view runs no WebAssembly, as WebKit's in Lockdown Mode: the reason it gives,
 *              and an import that ends with that reason before anything is written.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 *
 * Usage: node --test Plugin/tests/
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { NotionImportEngine, webAssemblyUnavailableReason } = require('../src/importer-engine.js');

const lockdownWords = /needs WebAssembly.*Lockdown Mode.*Import › From Notion/s;

test('WebAssembly as Node gives it runs the module', () => {
    assert.equal(webAssemblyUnavailableReason(), null);
});

test('no WebAssembly object, as in Lockdown Mode, is named with Lockdown Mode and the way around it', () => {
    assert.match(webAssemblyUnavailableReason({}), lockdownWords);
    assert.match(webAssemblyUnavailableReason({ WebAssembly: null }), lockdownWords);
});

test('a WebAssembly lacking what the engine calls, or refusing the empty module, is unavailable too', () => {
    const working = globalThis.WebAssembly;
    assert.match(webAssemblyUnavailableReason({ WebAssembly: { compile: working.compile } }), lockdownWords);
    assert.match(webAssemblyUnavailableReason({ WebAssembly: { ...webAssemblyFunctions(), validate: () => false } }), lockdownWords);
    assert.match(webAssemblyUnavailableReason({
        WebAssembly: { ...webAssemblyFunctions(), validate: () => { throw new Error('off'); } },
    }), lockdownWords);
    assert.equal(webAssemblyUnavailableReason({ WebAssembly: webAssemblyFunctions() }), null);
});

test('an import without WebAssembly ends with the reason and writes nothing', async () => {
    const writes = [];
    const vault = {
        configDir: '.obsidian',
        exists: async () => false,
        createFolder: async (path) => { writes.push(path); },
        createBinary: async (path) => { writes.push(path); },
        list: async () => ({ files: [], folders: [] }),
        read: async () => '',
        write: async (path) => { writes.push(path); },
        rename: async () => {},
        remove: async () => {},
    };
    const engine = new NotionImportEngine(new Uint8Array(0), vault);
    const export_ = new Blob([new Uint8Array(16)]);
    export_.name = 'Export.zip';
    const working = globalThis.WebAssembly;
    delete globalThis.WebAssembly;
    try {
        await assert.rejects(
            engine.importNotionExport({ files: [export_], folder: 'Notion', date: '2026-11-27', exportYear: 2026 }),
            (error) => lockdownWords.test(error.message),
        );
    } finally {
        globalThis.WebAssembly = working;
    }
    assert.deepEqual(writes, []);
});

/// Node's WebAssembly functions, bound, as a plain object.
function webAssemblyFunctions() {
    const working = globalThis.WebAssembly;
    return {
        compile: working.compile.bind(working),
        instantiate: working.instantiate.bind(working),
        validate: working.validate.bind(working),
    };
}
