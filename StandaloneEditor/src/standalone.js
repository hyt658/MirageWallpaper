// Mirage Wallpaper
// Copyright © 2026 王孝慈. All rights reserved.
// macOS integration for the original editor / 原版编辑器的 macOS 适配。
(() => {
    const session = window.mirageEditorSession;
    if (!session) return;
    const settingsKey = 'mirage.editor.settings.v1';
    document.documentElement.lang = session.language === 'zh-chs' ? 'zh-Hans' : session.language === 'zh-cht' ? 'zh-Hant' : session.language;
    async function watchAppearance() {
        let previous = '';
        while (true) {
            try {
                const response = await fetch(session.bridge.endpoint + '/appearance', {
                    method: 'POST', headers: {'Authorization': 'Bearer ' + session.bridge.token, 'X-Mirage-Appearance': previous}
                });
                if (!response.ok) throw new Error(String(response.status));
                const result = await response.json();
                if (result.appearance === 'dark' || result.appearance === 'light') {
                    previous = result.appearance;
                    document.documentElement.dataset.mirageAppearance = previous;
                }
            } catch (_) { await new Promise(resolve => setTimeout(resolve, 10000)); }
        }
    }
    if (location.hash.startsWith('#/editor')) watchAppearance();
    let choosingProject = false;
    window.mirageEditor = {
        brandTranslations(translations) {
            for (const key of Object.keys(translations)) {
                if (typeof translations[key] === 'string') translations[key] = translations[key].replace(/Wallpaper Engine/g, 'Mirage Editor');
            }
            Object.assign(translations, {
                ui_caption_editor: 'Mirage Editor',
                ui_editor_welcome_modal_title: 'Mirage Editor',
                mirage_about: session.language === 'zh-chs' ? '关于 Mirage Editor' : session.language === 'zh-cht' ? '關於 Mirage Editor' : 'About Mirage Editor'
            });
            return translations;
        },
        filterMenu(menu) {
            return menu.filter(item => item.label !== 'ui_editor_filemenu_provider').map(item => {
                if (item.label === 'ui_editor_filemenu_help') {
                    return {label: item.label, children: [{label: 'mirage_about', icon: 'fas fa-info-circle', fn: () => window.mirageEditor.about()}]};
                }
                if (item.children) item.children = item.children.filter(child => child.label !== 'ui_editor_filemenu_apply_wallpaper');
                return item;
            });
        },
        async about() {
            await fetch(session.bridge.endpoint + '/about', {
                method: 'POST', headers: {'Authorization': 'Bearer ' + session.bridge.token}
            });
        },
        async zoom() {
            await fetch(session.bridge.endpoint + '/window/zoom', {
                method: 'POST', headers: {'Authorization': 'Bearer ' + session.bridge.token}
            });
        },
        saveSettings(settings) { localStorage.setItem(settingsKey, JSON.stringify(settings)); },
        async openExternalProject() {
            if (choosingProject) return;
            choosingProject = true;
            try {
                const response = await fetch(session.bridge.endpoint + '/open-project', {
                    method: 'POST', headers: {'Authorization': 'Bearer ' + session.bridge.token}
                });
                if (!response.ok) throw new Error('Native project picker: ' + response.status);
                const result = await response.json();
                window.rootScope.$evalAsync(() => {
                    if (result.file) window.editorCtrl.requestOpenProject({file: result.file});
                    if (result.error) window.editorCtrl.showGenericError({title: 'ui_editor_filemenu_open', message: result.error});
                });
            } catch (error) {
                window.ui.logError('Mirage project picker: ' + error.message);
                const message = session.language === 'zh-chs' ? '无法打开工程选择器，请重新启动编辑器后重试。' :
                    session.language === 'zh-cht' ? '無法開啟工程選擇器，請重新啟動編輯器後重試。' :
                    'Unable to open the project picker. Restart the editor and try again.';
                window.rootScope.$evalAsync(() => window.editorCtrl.showGenericError({title: 'ui_editor_filemenu_open', message}));
            } finally { choosingProject = false; }
        }
    };
    let attempts = 0;
    function initialize() {
        if (!window.editorCtrl || !window.editorObject || !window.rootScope) {
            if (++attempts < 200) setTimeout(initialize, 50);
            return;
        }
        let saved = {};
        try { saved = JSON.parse(localStorage.getItem(settingsKey) || '{}'); } catch (_) {}
        window.rootScope.$evalAsync(() => {
            window.utilsService.setLanguage(session.language);
            window.editorCtrl.setEditorSettings({editor: Object.assign({}, session.defaults, saved), config: session.project ? {initialCommands: JSON.stringify({file: session.project})} : {}});
        });
    }
    window.addEventListener('DOMContentLoaded', initialize);
})();
