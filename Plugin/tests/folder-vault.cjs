/**
 * File: folder-vault.cjs
 * ----------------------
 * Layer: Tests
 * Description: A vault that is a folder on disk, with the members of the plugin API the import engine uses, so the
 *              plugin's import runs in Node and its result can be compared with the linked package's.
 *
 * Authors: Bahey Shalash
 * Version: 0.2
 * Date: 27/11/2026
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

class FolderVault {
    /// `canAppend` false leaves out `appendBinary`, as an app whose adapter has none, so files are written whole.
    constructor(folder, { canAppend = true } = {}) {
        this.folder = folder;
        this.configDir = '.obsidian';
        this.writes = 0;
        /// The most bytes one call wrote.
        this.largestWrite = 0;
        if (!canAppend) this.appendBinary = undefined;
    }

    full(vaultPath) {
        return path.join(this.folder, ...vaultPath.split('/').filter((name) => name !== ''));
    }

    async exists(vaultPath) {
        return fs.existsSync(this.full(vaultPath));
    }

    async createFolder(vaultPath) {
        if (fs.existsSync(this.full(vaultPath))) throw new Error('Folder already exists.');
        fs.mkdirSync(this.full(vaultPath), { recursive: true });
    }

    async createBinary(vaultPath, data) {
        const target = this.full(vaultPath);
        if (fs.existsSync(target)) throw new Error('File already exists.');
        fs.writeFileSync(target, Buffer.from(data), { flag: 'wx' });
        this.counted(data.byteLength);
    }

    async appendBinary(vaultPath, data) {
        fs.appendFileSync(this.full(vaultPath), Buffer.from(data));
        this.counted(data.byteLength);
    }

    async rename(vaultPath, newPath) {
        if (fs.existsSync(this.full(newPath))) throw new Error('Destination file already exists!');
        fs.renameSync(this.full(vaultPath), this.full(newPath));
    }

    async remove(vaultPath) {
        fs.rmSync(this.full(vaultPath));
    }

    counted(byteCount) {
        this.writes += 1;
        this.largestWrite = Math.max(this.largestWrite, byteCount);
    }

    async list(vaultPath) {
        const relative = vaultPath === '/' ? '' : vaultPath;
        const entries = fs.readdirSync(this.full(relative), { withFileTypes: true });
        const prefix = relative === '' ? '' : relative + '/';
        return {
            files: entries.filter((entry) => entry.isFile()).map((entry) => prefix + entry.name),
            folders: entries.filter((entry) => entry.isDirectory()).map((entry) => prefix + entry.name),
        };
    }

    async read(vaultPath) {
        return fs.readFileSync(this.full(vaultPath), 'utf8');
    }

    async write(vaultPath, text) {
        fs.writeFileSync(this.full(vaultPath), text);
        this.counted(Buffer.byteLength(text));
    }
}

module.exports = { FolderVault };
