# macOS Reminders HTTP server

The [Swift server](docs/SERVER.md) serves
`POST /graphql`, `POST /mcp`, and `GET /metrics` on `127.0.0.1:8081`.
EventKit reads and Reminders automation run in the server process. The
[data-access code](docs/DATA_ACCESS.md) is statically linked into the executable.

```sh
swift build -c release
./.build/release/reminders-swift --request-access
```

Requires macOS 14+ and Swift 6.4+ to build. `--request-access` explicitly requests
Reminders permission; omit it once permission is granted. Reminders flag reads use
AppleScript automatically and require separate Automation permission.
GraphQL reads flags only when selected or filtered; discovery and list
summaries stay EventKit-only. MCP reminder reads enrich flags; metrics use EventKit only.
Metrics refresh at startup and then hourly; `--metrics-interval-seconds` changes
the background delay. HTTP scrapes only read the cached snapshot.
See [automation behavior](docs/APPLESCRIPT.md) and [metrics](docs/METRICS.md).

GraphQL and MCP support reminder create/update/delete in editable lists. See
[write mutations](docs/WRITES.md) for supported fields. Server configuration
uses explicit startup options only; environment-variable configuration is prohibited.
It binds to loopback, rejects foreign browser origins, and has no authentication.
It is intended for local use. Introspection and MCP discovery describe the actual
supported API; the documentation includes schema and catalog references.

See the [documentation index](docs/README.md) for API and data-access references.

## Layout

- `Package.swift`, `Package.resolved`, and `Info.plist`: root package and app metadata.
- `Sources/RemindersServer/`: one executable target with a flat source layout.
  Files are named for their roles: HTTP, GraphQL, MCP, metrics, records, input
  validation, and EventKit/AppleScript access.
- `docs/`: server guide, API references, and data-access documentation.

## Nix

The root [flake](flake.nix) provides `default` and `swift` packages for Apple
Silicon macOS (`aarch64-darwin`). It tracks `nixpkgs-unstable`; `flake.lock` pins
the exact toolchain revision.

```sh
nix build
# Equivalent explicit package:
nix build .#swift
# Update the toolchain pin:
nix flake update nixpkgs
```

The package installs `result/bin/reminders-swift` with its data-access code embedded.
Builds do not run the server or access Reminders. The locked Nixpkgs currently
supplies Swift 6.2.4, while the server's locked dependencies require Swift 6.4.
The package reports this requirement until a suitable Nixpkgs compiler is available;
it does not fall back to local Xcode. No test suites run during packaging.
