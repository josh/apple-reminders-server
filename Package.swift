// swift-tools-version: 5.9

import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
  name: "apple-reminders-server",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "apple-reminders-server", targets: ["RemindersServer"])],
  dependencies: [
    .package(
      url: "https://github.com/GraphQLSwift/GraphQL.git",
      revision: "a83766b34139a855476166b1dc44d9ae9d8ecff4"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
  ],
  targets: [
    .executableTarget(
      name: "RemindersServer",
      dependencies: [
        .product(name: "GraphQL", package: "GraphQL"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Hummingbird", package: "hummingbird"),
      ],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker",
          root + "/Info.plist",
        ])
      ])
  ]
)
