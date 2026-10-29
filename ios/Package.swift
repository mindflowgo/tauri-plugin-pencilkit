// swift-tools-version:5.3
import PackageDescription

let package = Package(
  name: "tauri-plugin-pencilkit",
  platforms: [
    .macOS(.v10_13),
    .iOS(.v14),
  ],
  products: [
    .library(
      name: "tauri-plugin-pencilkit",
      type: .static,
      targets: ["tauri-plugin-pencilkit"])
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api")
  ],
  targets: [
    .target(
      name: "tauri-plugin-pencilkit",
      dependencies: [
        .byName(name: "Tauri")
      ],
      path: "Sources")
  ]
)
