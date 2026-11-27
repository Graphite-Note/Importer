/**
 * File: plugin.js
 * ---------------
 * Layer: Plugin
 * Description: The Notion importer as a community plugin: a command and a settings tab that open the import window,
 *              where Notion's HTML export is picked, imported with the Importer's WebAssembly module into a folder
 *              of the vault, followed page by page, stopped if asked, and its report note opened.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

'use strict';

const { Plugin, PluginSettingTab, Setting, Modal, Notice, normalizePath } = require('obsidian');

const DEFAULT_SETTINGS = Object.freeze({ folder: 'Notion' });

/// The module carried in this file as base64, decoded once.
let moduleBytes = null;
function importerModuleBytes() {
    if (!moduleBytes) {
        const text = atob(IMPORTER_MODULE_BASE64);
        moduleBytes = new Uint8Array(text.length);
        for (let index = 0; index < text.length; index += 1) moduleBytes[index] = text.charCodeAt(index);
    }
    return moduleBytes;
}

/// The vault as the engine writes it, through the plugin API.
function pluginVault(app) {
    return {
        configDir: app.vault.configDir || '.obsidian',
        exists: (path) => app.vault.adapter.exists(normalizePath(path)),
        createFolder: (path) => app.vault.createFolder(normalizePath(path)),
        createBinary: (path, data) => app.vault.createBinary(normalizePath(path), data),
        list: (path) => app.vault.adapter.list(path === '/' ? '/' : normalizePath(path)),
        read: (path) => app.vault.adapter.read(normalizePath(path)),
        write: (path, text) => app.vault.adapter.write(normalizePath(path), text),
    };
}

/// Today in the device's time zone, as the report writes it (2026-11-27).
function today() {
    const now = new Date();
    const pad = (number) => String(number).padStart(2, '0');
    return now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
}

/// The import window: the export picked, the folder, the import followed, stopped and reported.
class NotionImportModal extends Modal {
    constructor(app, plugin) {
        super(app);
        this.plugin = plugin;
        this.files = [];
        this.folder = plugin.settings.folder;
        this.engine = null;
    }

    onOpen() {
        const { contentEl } = this;
        this.setTitle ? this.setTitle('Import from Notion') : contentEl.createEl('h2', { text: 'Import from Notion' });
        contentEl.addClass('notion-importer');
        contentEl.createEl('p', {
            text: 'In Notion, open Settings, Export all workspace content, choose the format HTML, and pick the .zip it '
                + 'gives here. A large workspace comes as several Part-N zips: pick them together. Pages become notes, '
                + 'databases become bases, attachments are copied, and nothing already in the vault is replaced.',
        });

        new Setting(contentEl)
            .setName('Export')
            .setDesc('The .zip file, or its parts.')
            .then((setting) => {
                const input = setting.controlEl.createEl('input', { attr: { type: 'file', accept: '.zip,application/zip', multiple: '' } });
                input.addClass('notion-importer-file');
                input.addEventListener('change', () => {
                    this.files = Array.from(input.files || []);
                    this.updateButtons();
                });
                this.fileInput = input;
            });

        new Setting(contentEl)
            .setName('Folder')
            .setDesc('The vault folder the pages are imported into. Empty for the vault itself.')
            .addText((text) => text.setValue(this.folder).setPlaceholder('Notion').onChange((value) => { this.folder = value.trim(); }));

        this.progressEl = contentEl.createEl('progress', { cls: 'notion-importer-progress', attr: { max: '1', value: '0' } });
        this.progressEl.hidden = true;
        this.statusEl = contentEl.createEl('p', { cls: 'notion-importer-status' });

        const buttons = new Setting(contentEl);
        buttons.addButton((button) => {
            this.importButton = button;
            button.setButtonText('Import').setCta().onClick(() => this.runImport());
        });
        buttons.addButton((button) => {
            this.closeButton = button;
            button.setButtonText('Cancel').onClick(() => this.stopOrClose());
        });
        this.updateButtons();
    }

    updateButtons() {
        if (this.importButton) this.importButton.setDisabled(this.files.length === 0 || this.engine !== null);
    }

    stopOrClose() {
        if (this.engine) {
            this.statusEl.setText('Stopping after this page…');
            this.engine.cancel();
            return;
        }
        this.close();
    }

    async runImport() {
        if (this.files.length === 0 || this.engine) return;
        const folder = normalizePath(this.folder || '/') === '/' ? '' : normalizePath(this.folder);
        this.engine = new NotionImportEngine(importerModuleBytes(), pluginVault(this.app), this.plugin.request);
        this.plugin.runningEngine = this.engine;
        this.updateButtons();
        if (this.fileInput) this.fileInput.disabled = true;
        this.closeButton.setButtonText('Stop');
        this.progressEl.hidden = false;
        this.progressEl.removeAttribute('value');
        this.statusEl.setText('Reading the export…');
        try {
            const summary = await this.engine.importNotionExport({
                files: this.files,
                folder,
                date: today(),
                exportYear: new Date().getFullYear(),
                onProgress: (done, total) => {
                    this.progressEl.max = Math.max(total, 1);
                    this.progressEl.value = done;
                    this.statusEl.setText('Page ' + done + ' of ' + total);
                },
            });
            this.showSummary(summary);
        } catch (error) {
            this.progressEl.hidden = true;
            this.statusEl.setText('The import failed: ' + (error && error.message ? error.message : String(error)));
            this.statusEl.addClass('mod-warning');
        } finally {
            this.engine = null;
            this.plugin.runningEngine = null;
            if (this.fileInput) this.fileInput.disabled = false;
            this.closeButton.setButtonText('Close');
            this.updateButtons();
        }
    }

    showSummary(summary) {
        this.plugin.lastSummary = summary;
        const counts = summary.notes + ' notes, ' + summary.bases + ' bases and ' + summary.attachments + ' attachments';
        const findings = summary.simplified + summary.leftOut + summary.failed;
        this.statusEl.setText((summary.wasCancelled ? 'Stopped: ' : 'Imported ') + counts + ' in '
            + summary.seconds.toFixed(1) + ' s.' + (findings > 0 ? ' The report lists ' + findings + ' things to look at.' : ''));
        new Notice('Notion import: ' + counts + '.');
        const reportButton = new Setting(this.contentEl);
        reportButton.addButton((button) => button.setButtonText('Open the report').setCta().onClick(async () => {
            this.close();
            await this.app.workspace.openLinkText(summary.reportPath, '', false);
        }));
    }

    onClose() {
        if (this.engine) this.engine.cancel();
        this.contentEl.empty();
    }
}

class NotionImporterSettingTab extends PluginSettingTab {
    constructor(app, plugin) {
        super(app, plugin);
        this.plugin = plugin;
    }

    display() {
        const { containerEl } = this;
        containerEl.empty();
        new Setting(containerEl)
            .setName('Import Notion’s HTML export')
            .setDesc('Pages as notes, databases as bases with typed properties, attachments as files, and a report note of '
                + 'what was converted, simplified and left out.')
            .addButton((button) => button.setButtonText('Import…').setCta().onClick(() => new NotionImportModal(this.app, this.plugin).open()));
        new Setting(containerEl)
            .setName('Folder')
            .setDesc('Where imports go unless chosen otherwise in the import window. Empty for the vault itself.')
            .addText((text) => text.setPlaceholder('Notion').setValue(this.plugin.settings.folder).onChange(async (value) => {
                this.plugin.settings.folder = value.trim();
                await this.plugin.saveSettings();
            }));
        if (this.plugin.lastSummary) {
            const summary = this.plugin.lastSummary;
            new Setting(containerEl)
                .setName('Last import')
                .setDesc(summary.notes + ' notes, ' + summary.bases + ' bases, ' + summary.attachments + ' attachments, in '
                    + summary.seconds.toFixed(1) + ' s.')
                .addButton((button) => button.setButtonText('Open the report').onClick(() => {
                    this.app.workspace.openLinkText(summary.reportPath, '', false);
                }));
        }
    }
}

module.exports = class NotionImporterPlugin extends Plugin {
    async onload() {
        await this.loadSettings();
        this.runningEngine = null;
        this.lastSummary = null;
        let requestUrl = null;
        try {
            requestUrl = require('obsidian').requestUrl;
        } catch (error) {
            requestUrl = null;
        }
        this.request = requestUrl ? (options) => requestUrl(options) : null;
        this.addCommand({
            id: 'import-notion-export',
            name: 'Import Notion’s HTML export…',
            callback: () => new NotionImportModal(this.app, this).open(),
        });
        this.addSettingTab(new NotionImporterSettingTab(this.app, this));
    }

    onunload() {
        if (this.runningEngine) this.runningEngine.cancel();
    }

    async loadSettings() {
        this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
    }

    async saveSettings() {
        await this.saveData(this.settings);
    }
};
