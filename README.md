# Tauri Plugin PencilKit

High-performance Apple PencilKit integration for **Tauri v2** on iPadOS.

Provides native Metal-accelerated drawing, sub-9ms latency, Apple Pencil tilt & pressure dynamics, palm rejection, and Apple's native floating `PKToolPicker` palette.

## Features

- **Sub-9ms Metal Rendering**: Zero lag, ProMotion 120Hz display with 240Hz hardware touch scan.
- **Native Floating `PKToolPicker`**: Apple's native floating tool tray (Pen, Marker/Highlighter, Eraser, Ruler, Color Picker, and Apple Pencil 2/Pro double-tap gestures).
- **Passthrough Touch Routing**: Apple Pencil draws directly on native `PKCanvasView`, while direct finger touches pass straight through to the underlying `WKWebView` for scrolling, tapping, and navigation.
- **Live Scratchpad Architecture**: Drawings are converted to clean vector stroke structures upon pencil lift, preventing memory accumulation or Metal buffer bloat.

## Installation

### 1. Rust Setup
In your app's `Cargo.toml`:
```toml
[dependencies]
tauri-plugin-pencilkit = { version = "0.1", path = "./tauri-plugin-pencilkit" }
```

In your `main.rs` or `lib.rs`:
```rust
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_pencilkit::init())
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

### 2. Capabilities
Add `pencilkit:default` to your `capabilities/default.json`:
```json
{
  "permissions": [
    "core:default",
    "pencilkit:default"
  ]
}
```

### 3. JavaScript / TypeScript Usage
```typescript
import { setActive, setTool, onStrokeDrawn } from 'tauri-plugin-pencilkit';

// When entering markup mode:
await setActive({
  active: true,
  file: "file.md",
  authorWidth: 800,
  targetWidth: 800
});

// Listen for native strokes:
const unlisten = await onStrokeDrawn((stroke) => {
  console.log("Native stroke received:", stroke);
});
```

## License
MIT OR Apache-2.0
