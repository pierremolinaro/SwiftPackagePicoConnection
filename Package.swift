// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//--------------------------------------------------------------------------------------------------

import PackageDescription

//--------------------------------------------------------------------------------------------------

let package = Package (
  name: "PicoConnection",
  platforms: [.macOS (.v15)],
  products: [
    .library (name: "PicoConnection", targets: ["PicoConnection"])
  ],
  targets: [
    .target (name: "PicoConnection")
  ]
)

//--------------------------------------------------------------------------------------------------
