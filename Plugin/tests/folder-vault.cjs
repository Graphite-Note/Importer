/**
 * File: folder-vault.cjs
 * ----------------------
 * Layer: Tests
 * Description: A vault that is a folder on disk, with the members of the plugin API the import engine uses, so the
 *              plugin's import runs in Node and its result can be compared with the linked package's.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

class FolderVault {
    constructor(folder) {
        this.folder = folder;
        this.configDir = '.obsidian';
        this.writes = 0;
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
        this.writes += 1;
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
        this.writes += 1;
    }
}

module.exports = { FolderVault };
