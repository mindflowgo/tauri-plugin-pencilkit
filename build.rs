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
    "ack_rendered",
    "register_listener",
    "remove_listener",
];

fn main() {
    // Swift sources are compiled into the crate via swift-rs, which cargo cannot
    // track; force the build script to re-run when they change so stale Swift
    // never silently ships in a cached build.
    println!("cargo:rerun-if-changed=ios/Sources/PencilKitPlugin.swift");
    println!("cargo:rerun-if-changed=ios/Package.swift");

    let result = tauri_plugin::Builder::new(COMMANDS)
        .global_api_script_path("./api-iife.js")
        .ios_path("ios")
        .try_build();

    // Skip unwrap during docs.rs builds where native mobile tools/directories are not present
    if !(cfg!(docsrs) || std::env::var("DOCS_RS").is_ok()) {
        result.unwrap();
    }
}
