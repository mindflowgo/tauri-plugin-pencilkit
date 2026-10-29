import { addPluginListener, invoke, type PluginListener } from '@tauri-apps/api/core';

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
  lasso?: { enabled?: boolean } | boolean;
  ruler?: { enabled?: boolean } | boolean;
  allowsColorSelection?: boolean;
}

export const DEFAULT_TOOL_PICKER_CONFIG: ToolPickerOptions = {
  pencil: { enabled: true, color: 'blue', width: 3.5 },
  marker: { enabled: true, color: 'yellow', width: 24.0 },
  eraser: false,
  pen: false,
  lasso: false,
  ruler: false,
  allowsColorSelection: false
};

export interface PencilKitActiveOptions {
  active: boolean;
  file?: string;
  authorWidth?: number;
  targetWidth?: number;
  targetRect?: { x: number; y: number; width: number; height: number };
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

export async function isAvailable(): Promise<boolean> {
  try {
    const res = await invoke<{ available: boolean }>('plugin:pencilkit|is_available');
    return res.available;
  } catch {
    return false;
  }
}

export async function setActive(options: PencilKitActiveOptions): Promise<void> {
  const { tools, ...rest } = options;
  const payload: Record<string, unknown> = { ...rest };
  if (tools !== undefined) {
    payload.tools = tools;
  }
  await invoke('plugin:pencilkit|set_active', payload);
}

export async function configureTools(options: ToolPickerOptions = DEFAULT_TOOL_PICKER_CONFIG): Promise<void> {
  await invoke('plugin:pencilkit|configure_tools', { tools: options });
}

export async function setTool(
  tool: 'marker' | 'highlighter' | 'pencil' | 'eraser' | string,
  color?: string,
  width?: number
): Promise<void> {
  await invoke('plugin:pencilkit|set_tool', { tool, color, width });
}

export async function setExcludedRects(rects: ExcludedRect[], topHeight?: number): Promise<void> {
  await invoke('plugin:pencilkit|set_excluded_rects', { rects, topHeight });
}

export async function clear(): Promise<void> {
  await invoke('plugin:pencilkit|clear');
}

export async function syncUndoRedo(canUndo: boolean, canRedo: boolean): Promise<void> {
  await invoke('plugin:pencilkit|sync_undo_redo', { canUndo, canRedo });
}

export async function onUndo(callback: (info?: UndoActionInfo) => void): Promise<PluginListener> {
  return await addPluginListener<UndoActionInfo>('pencilkit', 'pencilkit:undo', callback);
}

export async function onRedo(callback: () => void): Promise<PluginListener> {
  return await addPluginListener('pencilkit', 'pencilkit:redo', callback);
}

export async function onStrokeDrawn(callback: (stroke: PencilKitStrokePayload) => void): Promise<PluginListener> {
  return await addPluginListener<PencilKitStrokePayload>('pencilkit', 'pencilkit:stroke-drawn', callback);
}

export async function onToolChanged(callback: (toolInfo: ToolChangeInfo) => void): Promise<PluginListener> {
  return await addPluginListener<ToolChangeInfo>('pencilkit', 'pencilkit:tool-changed', callback);
}

export async function onClosed(callback: () => void): Promise<PluginListener> {
  return await addPluginListener('pencilkit', 'pencilkit:closed', callback);
}
