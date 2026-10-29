import { type PluginListener } from '@tauri-apps/api/core';
export interface ToolItemConfig {
    enabled?: boolean;
    color?: string;
    width?: number;
}
export interface EraserConfig {
    enabled?: boolean;
    type?: 'vector' | 'bitmap';
    width?: number;
}
export interface ToolPickerOptions {
    pen?: ToolItemConfig | boolean;
    pencil?: ToolItemConfig | boolean;
    marker?: ToolItemConfig | boolean;
    eraser?: EraserConfig | boolean;
    lasso?: {
        enabled?: boolean;
    } | boolean;
    ruler?: {
        enabled?: boolean;
    } | boolean;
    allowsColorSelection?: boolean;
}
export declare const DEFAULT_TOOL_PICKER_CONFIG: ToolPickerOptions;
export interface PencilKitActiveOptions {
    active: boolean;
    file?: string;
    authorWidth?: number;
    targetWidth?: number;
    targetRect?: {
        x: number;
        y: number;
        width: number;
        height: number;
    };
    topHeight?: number;
    tools?: ToolPickerOptions;
    canUndo?: boolean;
    canRedo?: boolean;
}
export interface ExcludedRect {
    x: number;
    y: number;
    width: number;
    height: number;
}
export interface PencilKitStrokePayload {
    id: string;
    file: string;
    tool: 'marker' | 'highlighter' | 'pencil' | string;
    color: string;
    viewportPoints: number[];
    authorWidth: number;
    date: string;
    width?: number;
    opacity?: number;
}
export interface ToolChangeInfo {
    tool: string;
    color: string;
    width?: number;
    opacity?: number;
}
export interface UndoActionInfo {
    source?: 'toolbar' | 'double-tap' | string;
}
export declare function isAvailable(): Promise<boolean>;
export declare function setActive(options: PencilKitActiveOptions): Promise<void>;
export declare function configureTools(options?: ToolPickerOptions): Promise<void>;
export declare function setTool(tool: 'marker' | 'highlighter' | 'pencil' | 'eraser' | string, color?: string, width?: number): Promise<void>;
export declare function setExcludedRects(rects: ExcludedRect[], topHeight?: number): Promise<void>;
export declare function clear(): Promise<void>;
export declare function syncUndoRedo(canUndo: boolean, canRedo: boolean): Promise<void>;
export declare function onUndo(callback: (info?: UndoActionInfo) => void): Promise<PluginListener>;
export declare function onRedo(callback: () => void): Promise<PluginListener>;
export declare function onStrokeDrawn(callback: (stroke: PencilKitStrokePayload) => void): Promise<PluginListener>;
export declare function onToolChanged(callback: (toolInfo: ToolChangeInfo) => void): Promise<PluginListener>;
export declare function onClosed(callback: () => void): Promise<PluginListener>;
