/**
 * File: importer-engine.js
 * ------------------------
 * Layer: Plugin
 * Description: Runs the Importer's WebAssembly module: a small WASI for the module's own needs, and the host calls it
 *              makes, answered with the picked files (read by range with Blob.slice), the vault (written through the
 *              plugin API, never over a file already there) and temporary files kept as blobs.
 *
 * Authors: Bahey Shalash
 * Version: 0.3
 * Date: 27/11/2026
 */

'use strict';

/// The host calls of the module, as Plugin/Sources/ImporterWasm/HostBridge.swift numbers them.
const HostKind = Object.freeze({
    read: 1, createFolder: 2, writeNewFile: 3, createNewFile: 4, appendToFile: 5, closeFile: 6, names: 7,
    assignPropertyTypes: 8, makeTemporaryFile: 9, appendToTemporaryFile: 10, finishTemporaryFile: 11, request: 12,
});

const succeeded = 0;
const failed = 1;
const fileExists = 17;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

/// What the plugin says when the web view runs no WebAssembly. WebKit leaves `WebAssembly` undefined in Lockdown Mode
/// (on the iPhone, the iPad and the Mac), so an import there would otherwise end in a bare ReferenceError.
const webAssemblyUnavailableMessage = 'This importer needs WebAssembly, which this app\u2019s web view has turned off. '
    + 'In Lockdown Mode, WebKit turns WebAssembly off on the iPhone, the iPad and the Mac. '
    + 'In Graphite, Import \u203a From Notion\u2026 imports the export without it.';

/// The 8 bytes of an empty module: its magic number and version.
const emptyModule = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);

/// Why the module cannot run in `scope`, or null when it can: no `WebAssembly` object, one missing what the engine
/// calls, or one that refuses the empty module.
function webAssemblyUnavailableReason(scope = globalThis) {
    const webAssembly = scope.WebAssembly;
    if (typeof webAssembly !== 'object' || webAssembly === null) return webAssemblyUnavailableMessage;
    for (const name of ['compile', 'instantiate', 'validate']) {
        if (typeof webAssembly[name] !== 'function') return webAssemblyUnavailableMessage;
    }
    try {
        return webAssembly.validate(emptyModule) ? null : webAssemblyUnavailableMessage;
    } catch (error) {
        return webAssemblyUnavailableMessage;
    }
}

/// Texts separated by NUL, as the module passes them.
function joinedTexts(texts) {
    return textEncoder.encode(texts.join('\u0000'));
}

function splitTexts(bytes) {
    return bytes.length === 0 ? [] : textDecoder.decode(bytes).split('\u0000');
}

/// The last name of a vault path.
function baseName(path) {
    const position = path.lastIndexOf('/');
    return position < 0 ? path : path.slice(position + 1);
}

/// The bytes of `blob`. WebKit's blobs read themselves; a FileReader stands in where they do not (jsdom).
function blobBytes(blob) {
    if (typeof blob.arrayBuffer === 'function') return blob.arrayBuffer();
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsArrayBuffer(blob);
    });
}

/// `pieces` joined into one buffer.
function joinedBuffer(pieces) {
    const total = pieces.reduce((sum, piece) => sum + piece.length, 0);
    const joined = new Uint8Array(total);
    let offset = 0;
    for (const piece of pieces) {
        joined.set(piece, offset);
        offset += piece.length;
    }
    return joined.buffer;
}

/// A failure the module reports with these words.
class HostFailure extends Error {}

/// A file larger than this is written in pieces of about this size when the vault can append (`appendBinary`),
/// so that an attachment of hundreds of MB is never held whole, and no write exceeds what a host accepts in one
/// message (64 MB in Graphite).
const streamedPieceBytes = 16 * 1048576;

/// The hidden file in the same folder that a file written in pieces grows in, until it is complete and renamed.
function partPath(path, handle) {
    const slash = path.lastIndexOf('/');
    return path.slice(0, slash + 1) + '.' + path.slice(slash + 1) + '.notion-import-part-' + handle;
}

/**
 * The vault as the engine writes it. `vault` gives, as the plugin API does: `exists(path)`, `createFolder(path)`,
 * `createBinary(path, arrayBuffer)` (refusing an existing file), `list(path)` (`{ files, folders }` of full paths),
 * `read(path)` and `write(path, text)` for text, and `configDir`. When it also gives `appendBinary(path,
 * arrayBuffer)`, `rename(path, newPath)` (refusing an existing destination) and `remove(path)`, a large file is
 * written in pieces into a hidden file beside it, renamed once complete, and removed if the import ends first.
 * `request`, when given, sends a request as `requestUrl` does.
 */
class NotionImportEngine {
    constructor(moduleBytes, vault, request) {
        this.moduleBytes = moduleBytes;
        this.vault = vault;
        this.request = request || null;
        this.instance = null;
        this.sources = [];
        this.writers = new Map();
        /// The hidden files of files written in pieces that the import did not finish, removed when it ends.
        this.unfinishedParts = new Set();
        this.temporaryFiles = new Map();
        this.pendingPaths = new Set();
        this.nextHandle = 1;
        this.hostCallCount = 0;
        this.isBroken = false;
        this.isStopRequested = false;
    }

    canWriteInPieces() {
        return typeof this.vault.appendBinary === 'function' && typeof this.vault.rename === 'function'
            && typeof this.vault.remove === 'function';
    }

    /// Adds the pieces received so far to the file's hidden part, which the first append makes (through the
    /// adapter, since the vault's own API keeps out of hidden files).
    async writePieces(writer, handle) {
        if (!writer.partPath) {
            writer.partPath = partPath(writer.path, handle);
            // Left by an import that ended without removing it (the app was closed meanwhile).
            if (await this.vault.exists(writer.partPath)) await this.vault.remove(writer.partPath);
        }
        if (writer.pieceBytes === 0) return;
        const contents = joinedBuffer(writer.pieces);
        writer.pieces = [];
        writer.pieceBytes = 0;
        await this.vault.appendBinary(writer.partPath, contents);
    }

    /// Removes the hidden parts of files the import did not finish, so nothing half written stays in the vault.
    async removeUnfinishedParts() {
        for (const writer of this.writers.values()) {
            if (writer.partPath) this.unfinishedParts.add(writer.partPath);
        }
        for (const path of this.unfinishedParts) {
            try {
                if (await this.vault.exists(path)) await this.vault.remove(path);
            } catch (error) {
                // Left for the next import to remove: the import's own outcome is what is reported.
            }
        }
        this.unfinishedParts.clear();
    }

    /// The module's memory as bytes, read again after every call that may grow it.
    memoryBytes() {
        return new Uint8Array(this.instance.exports.memory.buffer);
    }

    copyOut(pointer, count) {
        return count > 0 ? this.memoryBytes().slice(pointer, pointer + count) : new Uint8Array(0);
    }

    /// Calls `body(pointer, count)` with `bytes` written into the module's memory, then frees them.
    withBytesInModule(bytes, body) {
        const exports = this.instance.exports;
        const pointer = exports.importer_alloc(Math.max(bytes.length, 1));
        this.memoryBytes().set(bytes, pointer);
        try {
            return body(pointer, bytes.length);
        } finally {
            exports.importer_free(pointer);
        }
    }

    /// WASI as far as the Swift runtime asks for it: output, the clocks and random numbers. Any other call is
    /// answered "not supported".
    wasiImports(module) {
        const engine = this;
        const notSupported = 52;
        const badDescriptor = 8;
        const functions = {
            fd_write(descriptor, vectors, vectorCount, writtenPointer) {
                const view = new DataView(engine.instance.exports.memory.buffer);
                let written = 0;
                let text = '';
                for (let index = 0; index < vectorCount; index += 1) {
                    const pointer = view.getUint32(vectors + index * 8, true);
                    const length = view.getUint32(vectors + index * 8 + 4, true);
                    text += textDecoder.decode(engine.memoryBytes().subarray(pointer, pointer + length));
                    written += length;
                }
                if (text.trim() !== '') (descriptor === 2 ? console.error : console.log)('Notion importer: ' + text.trim());
                view.setUint32(writtenPointer, written, true);
                return 0;
            },
            random_get(pointer, length) {
                const bytes = new Uint8Array(length);
                globalThis.crypto.getRandomValues(bytes);
                engine.memoryBytes().set(bytes, pointer);
                return 0;
            },
            clock_time_get(clock, precision, timePointer) {
                const nanoseconds = clock === 0 ? BigInt(Date.now()) * 1000000n
                    : BigInt(Math.round(globalThis.performance.now() * 1000000));
                new DataView(engine.instance.exports.memory.buffer).setBigUint64(timePointer, nanoseconds, true);
                return 0;
            },
            clock_res_get(clock, resolutionPointer) {
                new DataView(engine.instance.exports.memory.buffer).setBigUint64(resolutionPointer, 1000n, true);
                return 0;
            },
            // No arguments, no environment and no folders opened for the module.
            args_sizes_get(countPointer, sizePointer) {
                const view = new DataView(engine.instance.exports.memory.buffer);
                view.setUint32(countPointer, 0, true);
                view.setUint32(sizePointer, 0, true);
                return 0;
            },
            environ_sizes_get(countPointer, sizePointer) {
                const view = new DataView(engine.instance.exports.memory.buffer);
                view.setUint32(countPointer, 0, true);
                view.setUint32(sizePointer, 0, true);
                return 0;
            },
            args_get() {
                return 0;
            },
            environ_get() {
                return 0;
            },
            fd_prestat_get() {
                return badDescriptor;
            },
            proc_exit(code) {
                throw new Error('The Notion importer stopped (exit ' + code + ').');
            },
        };
        const wasi = {};
        for (const entry of WebAssembly.Module.imports(module)) {
            if (entry.module !== 'wasi_snapshot_preview1') continue;
            wasi[entry.name] = functions[entry.name] || (() => notSupported);
        }
        return wasi;
    }

    async instantiate() {
        const module = await WebAssembly.compile(this.moduleBytes);
        const engine = this;
        const imports = {
            wasi_snapshot_preview1: this.wasiImports(module),
            importer_host: {
                call(request, kind, argumentPointer, argumentCount, bytesPointer, byteCount) {
                    // The arguments are copied at once: the memory may grow and move before the answer.
                    const argumentsGiven = splitTexts(engine.copyOut(argumentPointer, argumentCount));
                    const bytes = engine.copyOut(bytesPointer, byteCount);
                    engine.hostCallCount += 1;
                    Promise.resolve()
                        .then(() => engine.answer(kind, argumentsGiven, bytes))
                        .catch((error) => ({ status: failed, bytes: textEncoder.encode(engine.clause(error)) }))
                        .then((answer) => engine.resume(request, answer));
                },
                progress(done, total) {
                    if (engine.onProgress) engine.onProgress(done, total);
                },
                finished(status, pointer, count) {
                    const texts = splitTexts(engine.copyOut(pointer, count));
                    engine.finish(status, texts);
                },
            },
        };
        this.instance = await WebAssembly.instantiate(module, imports);
        this.instance.exports._initialize();
    }

    reason(error) {
        if (error && typeof error.message === 'string' && error.message !== '') return error.message;
        return String(error);
    }

    /// The reason as the report quotes it, inside its own sentence: without the final full stop that the app's
    /// messages end with ("…could not be copied: The disk is full." rather than "full..").
    clause(error) {
        return this.reason(error).replace(/\.$/, '');
    }

    /// Gives the module its answer. A trap (a Swift runtime error) ends the import: the instance cannot be used again.
    resume(request, answer) {
        if (this.isBroken) return;
        try {
            this.withBytesInModule(answer.bytes, (pointer, count) => {
                this.instance.exports.importer_resume(request, answer.status, pointer, count);
            });
        } catch (error) {
            this.isBroken = true;
            this.finish(failed, ['the importer stopped on an error of its own (' + this.reason(error) + ')']);
        }
    }

    finish(status, texts) {
        const settle = this.settle;
        this.settle = null;
        if (settle) settle(status, texts);
    }

    /// Answers one host call: `{ status, bytes }`.
    async answer(kind, given, bytes) {
        const done = (answerBytes) => ({ status: succeeded, bytes: answerBytes || new Uint8Array(0) });
        switch (kind) {
            case HostKind.read: {
                const source = this.sources[Number(given[0])];
                if (!source) throw new HostFailure('the import asked for a file it was not given');
                const offset = Number(given[1]);
                const piece = source.slice(offset, offset + Number(given[2]));
                return done(new Uint8Array(await blobBytes(piece)));
            }
            case HostKind.createFolder: {
                // The folder and the folders above it, as the module asks.
                const names = given[0].split('/').filter((name) => name !== '');
                for (let count = 1; count <= names.length; count += 1) {
                    const path = names.slice(0, count).join('/');
                    if (!(await this.vault.exists(path))) await this.vault.createFolder(path);
                }
                return done();
            }
            case HostKind.writeNewFile: {
                const path = given[0];
                if (this.pendingPaths.has(path) || await this.vault.exists(path)) return { status: fileExists, bytes: new Uint8Array(0) };
                try {
                    await this.vault.createBinary(path, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
                } catch (error) {
                    // Written meanwhile by someone else: the vault refused to replace it.
                    if (/already exists/i.test(this.reason(error))) return { status: fileExists, bytes: new Uint8Array(0) };
                    throw error;
                }
                return done();
            }
            case HostKind.createNewFile: {
                const path = given[0];
                if (this.pendingPaths.has(path) || await this.vault.exists(path)) return { status: fileExists, bytes: new Uint8Array(0) };
                const handle = String(this.nextHandle++);
                this.pendingPaths.add(path);
                this.writers.set(handle, { path, pieces: [], pieceBytes: 0, partPath: null });
                return done(textEncoder.encode(handle));
            }
            case HostKind.appendToFile: {
                const writer = this.writers.get(given[0]);
                if (!writer) throw new HostFailure('the import wrote to a file it had not made');
                writer.pieces.push(bytes);
                writer.pieceBytes += bytes.length;
                if (writer.pieceBytes >= streamedPieceBytes && this.canWriteInPieces()) await this.writePieces(writer, given[0]);
                return done();
            }
            case HostKind.closeFile: {
                const writer = this.writers.get(given[0]);
                if (!writer) throw new HostFailure('the import closed a file it had not made');
                this.writers.delete(given[0]);
                try {
                    if (writer.partPath) {
                        // Written in pieces: the rest added, then the complete file put in its place.
                        await this.writePieces(writer, given[0]);
                        await this.vault.rename(writer.partPath, writer.path);
                        writer.partPath = null;
                    } else {
                        // Small enough, or a vault that cannot append: the pieces are joined once, the file written whole.
                        const contents = joinedBuffer(writer.pieces);
                        writer.pieces = [];
                        await this.vault.createBinary(writer.path, contents);
                    }
                } finally {
                    this.pendingPaths.delete(writer.path);
                    if (writer.partPath) this.unfinishedParts.add(writer.partPath);
                }
                return done();
            }
            case HostKind.names: {
                const path = given[0];
                const names = new Set();
                if (path === '' || await this.vault.exists(path)) {
                    const listing = await this.vault.list(path === '' ? '/' : path);
                    for (const entry of listing.files.concat(listing.folders)) names.add(baseName(entry));
                }
                const prefix = path === '' ? '' : path + '/';
                for (const pending of this.pendingPaths) {
                    if (pending.startsWith(prefix) && !pending.slice(prefix.length).includes('/')) names.add(pending.slice(prefix.length));
                }
                return done(joinedTexts([...names]));
            }
            case HostKind.assignPropertyTypes:
                return done(joinedTexts(await this.assignPropertyTypes(given)));
            case HostKind.makeTemporaryFile: {
                const handle = String(this.nextHandle++);
                this.temporaryFiles.set(handle, []);
                return done(textEncoder.encode(handle));
            }
            case HostKind.appendToTemporaryFile: {
                const pieces = this.temporaryFiles.get(given[0]);
                if (!pieces) throw new HostFailure('the import wrote to a temporary file it had not made');
                pieces.push(bytes);
                return done();
            }
            case HostKind.finishTemporaryFile: {
                const pieces = this.temporaryFiles.get(given[0]);
                if (!pieces) throw new HostFailure('the import finished a temporary file it had not made');
                this.temporaryFiles.delete(given[0]);
                const blob = new Blob(pieces);
                this.sources.push(blob);
                return done(joinedTexts([String(this.sources.length - 1), String(blob.size)]));
            }
            case HostKind.request: {
                if (!this.request) throw new HostFailure('this host sends no requests');
                const [method, url, ...headerLines] = given;
                const headers = {};
                for (const line of headerLines) {
                    const colon = line.indexOf(':');
                    if (colon > 0) headers[line.slice(0, colon).trim()] = line.slice(colon + 1).trim();
                }
                const response = await this.request({ method, url, headers, body: bytes.length > 0 ? bytes.buffer : undefined, throw: false });
                return { status: response.status, bytes: new Uint8Array(response.arrayBuffer || new ArrayBuffer(0)) };
            }
            default:
                throw new HostFailure('the import asked for something this plugin does not know (' + kind + ')');
        }
    }

    /// The property types of `pairs` (name, type, name, type…) added to the vault's types.json, every type already
    /// there kept. Returns the names whose type there differs.
    async assignPropertyTypes(pairs) {
        const path = (this.vault.configDir || '.obsidian') + '/types.json';
        let document = {};
        if (await this.vault.exists(path)) {
            try {
                document = JSON.parse(await this.vault.read(path));
            } catch (error) {
                document = null;
            }
            if (document === null || typeof document !== 'object' || Array.isArray(document)) {
                throw new HostFailure(path + ' is not the JSON object Obsidian writes, so it was left as it is');
            }
        }
        const assigned = document.types === undefined ? {} : document.types;
        if (assigned === null || typeof assigned !== 'object' || Array.isArray(assigned)) {
            throw new HostFailure(path + ' is not the JSON object Obsidian writes, so it was left as it is');
        }
        const conflicting = [];
        let isChanged = false;
        for (let index = 0; index + 1 < pairs.length; index += 2) {
            const name = pairs[index];
            const type = pairs[index + 1];
            const existing = Object.keys(assigned).find((key) => key.toLowerCase() === name.toLowerCase());
            if (existing !== undefined) {
                if (assigned[existing] !== type) conflicting.push(name);
                continue;
            }
            assigned[name] = type;
            isChanged = true;
        }
        if (!isChanged) return conflicting;
        const sorted = {};
        for (const key of Object.keys(assigned).sort()) sorted[key] = assigned[key];
        document.types = sorted;
        const folder = path.slice(0, path.lastIndexOf('/'));
        if (!(await this.vault.exists(folder))) await this.vault.createFolder(folder);
        await this.vault.write(path, JSON.stringify(document, null, 2));
        return conflicting;
    }

    /**
     * Imports Notion's HTML export, the picked `files` (blobs with names: a zip, its parts, a zip of zips) into
     * `folder` of the vault. `onProgress(done, total)` hears of each page. Resolves with the import's summary, or
     * rejects with the reason it could not run.
     */
    async importNotionExport({ files, folder, date, exportYear, onProgress }) {
        if (this.instance) throw new Error('An engine runs one import.');
        const unavailable = webAssemblyUnavailableReason();
        if (unavailable) throw new Error(unavailable);
        await this.instantiate();
        this.onProgress = onProgress || null;
        const given = [folder || '', files.map((file) => file.name).join(', '), date, String(exportYear)];
        for (const file of files) {
            this.sources.push(file);
            given.push(String(this.sources.length - 1), String(file.size), file.name);
        }
        const started = Date.now();
        const result = new Promise((resolve, reject) => {
            this.settle = (status, texts) => {
                if (status !== succeeded) {
                    reject(new Error(texts[0] || 'The import failed.'));
                    return;
                }
                resolve({
                    reportPath: texts[0], wasCancelled: texts[1] === '1', notes: Number(texts[2]), bases: Number(texts[3]),
                    attachments: Number(texts[4]), simplified: Number(texts[5]), leftOut: Number(texts[6]), failed: Number(texts[7]),
                    seconds: (Date.now() - started) / 1000, hostCalls: this.hostCallCount,
                    moduleMemoryMB: Math.round(this.instance.exports.memory.buffer.byteLength / 1048576),
                });
            };
        });
        try {
            this.withBytesInModule(joinedTexts(given), (pointer, count) => this.instance.exports.importer_notion_import(pointer, count));
            // Stop pressed while the module was still being made.
            if (this.isStopRequested) this.instance.exports.importer_cancel();
        } catch (error) {
            this.isBroken = true;
            this.finish(failed, ['the importer stopped on an error of its own (' + this.reason(error) + ')']);
        }
        try {
            return await result;
        } finally {
            await this.removeUnfinishedParts();
        }
    }

    /// Stops the import at its next page. Its report is still written, and the promise resolves with `wasCancelled`.
    cancel() {
        this.isStopRequested = true;
        if (this.instance && this.settle && !this.isBroken) this.instance.exports.importer_cancel();
    }
}

if (typeof module !== 'undefined' && module.exports && typeof exports !== 'undefined') {
    module.exports.NotionImportEngine = NotionImportEngine;
    module.exports.webAssemblyUnavailableReason = webAssemblyUnavailableReason;
}
