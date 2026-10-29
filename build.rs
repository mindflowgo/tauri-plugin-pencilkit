// Copyright 2026 CourseDeck
// SPDX-License-Identifier: Apache-2.0 OR MIT

const COMMANDS: &[&str] = &[
    "set_active",
    "set_tool",
    "clear",
    "is_available",
    "set_excluded_rects",
    "configure_tools",
    "sync_undo_redo",
    "register_listener",
    "remove_listener",
];

fn main() {
    let result = tauri_plugin::Builder::new(COMMANDS)
        .global_api_script_path("./api-iife.js")
        .ios_path("ios")
        .try_build();

    // Skip unwrap during docs.rs builds where native mobile tools/directories are not present
    if !(cfg!(docsrs) || std::env::var("DOCS_RS").is_ok()) {
        result.unwrap();
    }
}
