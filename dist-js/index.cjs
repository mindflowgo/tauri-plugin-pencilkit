'use strict';

var core = require('@tauri-apps/api/core');

const DEFAULT_TOOL_PICKER_CONFIG = {
    pencil: { enabled: true, color: 'blue', width: 3.5 },
    marker: { enabled: true, color: 'yellow', width: 24.0 },
    eraser: false,
    pen: false,
    lasso: false,
    ruler: false,
    allowsColorSelection: false
};
async function isAvailable() {
    try {
        const res = await core.invoke('plugin:pencilkit|is_available');
        return res.available;
    }
    catch {
        return false;
    }
}
async function setActive(options) {
    const { tools, ...rest } = options;
    const payload = { ...rest };
    if (tools !== undefined) {
        payload.tools = tools;
    }
    await core.invoke('plugin:pencilkit|set_active', payload);
}
async function configureTools(options = DEFAULT_TOOL_PICKER_CONFIG) {
    await core.invoke('plugin:pencilkit|configure_tools', { tools: options });
}
async function setTool(tool, color, width) {
    await core.invoke('plugin:pencilkit|set_tool', { tool, color, width });
}
async function setExcludedRects(rects, topHeight) {
    await core.invoke('plugin:pencilkit|set_excluded_rects', { rects, topHeight });
}
async function clear() {
    await core.invoke('plugin:pencilkit|clear');
}
async function syncUndoRedo(canUndo, canRedo) {
    await core.invoke('plugin:pencilkit|sync_undo_redo', { canUndo, canRedo });
}
async function onUndo(callback) {
    return await core.addPluginListener('pencilkit', 'pencilkit:undo', callback);
}
async function onRedo(callback) {
    return await core.addPluginListener('pencilkit', 'pencilkit:redo', callback);
}
async function onStrokeDrawn(callback) {
    return await core.addPluginListener('pencilkit', 'pencilkit:stroke-drawn', callback);
}
async function onToolChanged(callback) {
    return await core.addPluginListener('pencilkit', 'pencilkit:tool-changed', callback);
}
async function onClosed(callback) {
    return await core.addPluginListener('pencilkit', 'pencilkit:closed', callback);
}

exports.DEFAULT_TOOL_PICKER_CONFIG = DEFAULT_TOOL_PICKER_CONFIG;
exports.clear = clear;
exports.configureTools = configureTools;
exports.isAvailable = isAvailable;
exports.onClosed = onClosed;
exports.onRedo = onRedo;
exports.onStrokeDrawn = onStrokeDrawn;
exports.onToolChanged = onToolChanged;
exports.onUndo = onUndo;
exports.setActive = setActive;
exports.setExcludedRects = setExcludedRects;
exports.setTool = setTool;
exports.syncUndoRedo = syncUndoRedo;
