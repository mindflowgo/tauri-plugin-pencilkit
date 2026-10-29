// Copyright 2026 CourseDeck
// SPDX-License-Identifier: Apache-2.0 OR MIT

//! High-performance Apple PencilKit integration for Tauri on iPadOS.
//!
//! Provides native Metal-accelerated drawing, sub-9ms latency, Apple Pencil tilt & pressure,
//! and the native iOS PKToolPicker floating palette.
//!
//! On non-iOS targets, gracefully stubs out operations so universal codebases compile cleanly.

#[cfg(not(target_os = "ios"))]
use std::marker::PhantomData;
use tauri::{
    plugin::{Builder, TauriPlugin},
    Manager, Runtime,
};

#[cfg(target_os = "ios")]
use tauri::plugin::PluginHandle;

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_pencilkit);

/// Handle to the PencilKit plugin.
pub struct PencilKit<R: Runtime> {
    #[cfg(target_os = "ios")]
    #[allow(dead_code)]
    handle: PluginHandle<R>,
    #[cfg(not(target_os = "ios"))]
    _marker: PhantomData<fn() -> R>,
}

impl<R: Runtime> PencilKit<R> {
    pub fn is_available(&self) -> bool {
        cfg!(target_os = "ios")
    }
}

/// Extension trait to access PencilKit on Tauri instances.
pub trait PencilKitExt<R: Runtime> {
    fn pencilkit(&self) -> &PencilKit<R>;
}

impl<R: Runtime, T: Manager<R>> PencilKitExt<R> for T {
    fn pencilkit(&self) -> &PencilKit<R> {
        self.state::<PencilKit<R>>().inner()
    }
}

#[cfg(not(target_os = "ios"))]
#[derive(serde::Serialize)]
struct AvailabilityResponse {
    available: bool,
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn is_available() -> AvailabilityResponse {
    AvailabilityResponse { available: false }
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn set_active() -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn set_tool() -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn clear() -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn set_excluded_rects() -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn configure_tools() -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn sync_undo_redo() -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn ack_rendered(_ids: Vec<String>) -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn register_listener() -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
fn remove_listener() -> Result<(), String> {
    Ok(())
}

/// Initializes the PencilKit plugin.
pub fn init<R: Runtime>() -> TauriPlugin<R> {
    #[allow(unused_mut)]
    let mut builder = Builder::new("pencilkit");

    #[cfg(not(target_os = "ios"))]
    {
        builder = builder.invoke_handler(tauri::generate_handler![
            is_available,
            set_active,
            set_tool,
            clear,
            set_excluded_rects,
            configure_tools,
            sync_undo_redo,
            ack_rendered,
            register_listener,
            remove_listener,
        ]);
    }

    builder
        .setup(|app, _api| {
            #[cfg(target_os = "ios")]
            {
                let handle = _api.register_ios_plugin(init_plugin_pencilkit)?;
                app.manage(PencilKit { handle });
            }
            #[cfg(not(target_os = "ios"))]
            {
                app.manage(PencilKit {
                    _marker: PhantomData::<fn() -> R>,
                });
            }
            Ok(())
        })
        .build()
}
