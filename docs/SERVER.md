# HTTP server

The server runs on macOS 14+ and exposes three endpoints on `127.0.0.1`:

| Endpoint | Purpose | Reference |
| --- | --- | --- |
| `POST /graphql` | Queries, mutations, and introspection | [Read API](READ_API.md), [schema](reminders.graphql) |
| `POST /mcp` | MCP discovery and tool calls | [MCP API](MCP.md), [tool catalog](mcp-tools.json) |
| `GET /metrics` | Cached Prometheus data metrics | [Metrics](METRICS.md) |

Reminder and list writes honor EventKit authorization and editability. See
[WRITES.md](WRITES.md) for supported inputs and failures after a save.

## Build and startup

Build with Swift 6.4+ and the macOS SDK:

```sh
swift build -c release
.build/release/apple-reminders-server --request-access
```

Omit `--request-access` after permission is granted. Startup options are the only
configuration interface; environment-variable configuration is not supported.

| Option | Default | Behavior |
| --- | --- | --- |
| `--port` | `8171` | Loopback listener port, 1–65535 |
| `--metrics-interval-seconds` | `3600` | Delay after each metrics collection, 1–604800 seconds |
| `--log-level <level>` | `info` | Minimum log level: `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical` |
| `--allowed-origin <origin>` | None | Repeatable additional browser origin, `http(s)://host[:port]` |
| `--tailscale-app-capability <name>` | Off | Apply Tailscale permissions when given |
| `--request-access` | Off | Explicitly request EventKit access at startup |
| `--help`, `-h` | — | Show usage |

## Permissions and execution

EventKit and AppleScript run inside the server process. EventKit permission is
requested only through the explicit startup option, not in response to a read.
EventKit grants full reminder access rather than a read-only grant. Automation
permission is separate and may be requested when an operation first sends Apple
events to Reminders. Startup metrics collection uses EventKit only.

Permission attribution and persistence depend on the executable's signing and
launch context. The current build embeds usage descriptions but does not produce
a signed application bundle or install a background service.

## HTTP behavior

Hummingbird hosts HTTP/1.1, including concurrent requests, keep-alive, chunked
request decoding, and graceful SIGINT/SIGTERM shutdown. The MCP SDK handles
stateless protocol adaptation and tool dispatch; Hummingbird owns the listener.
GraphQLSwift handles parsing, validation, execution, and introspection.
Dependencies are pinned in `Package.resolved`.

Host is not validated; run network access through a trusted proxy such as
Tailscale Serve. Origin, when present, must be `http://localhost:<port>`,
`http://127.0.0.1:<port>`, or an origin given by `--allowed-origin`; other origins
return 403. Allowed origins receive CORS headers and OPTIONS preflight support.
Origins must have no path, query, fragment, or credentials. JSON POSTs require
`Content-Type: application/json`; other media types return 415. Request bodies
are limited to 1 MiB, including chunked uploads; excess returns 413.

There is no built-in identity authentication or TLS, so keep the service local
or put it behind a trusted proxy with its own access controls. GraphQL
subscriptions and MCP SSE streams are not implemented. MCP protocol details are
in [MCP.md](MCP.md).

## Limits

Accounts are derived from accessible reminder lists. The default account is
inferred from the default list. Inventory reads are not atomic database
snapshots, and accessible records do not establish complete cloud synchronization.
Identifiers may change after a full sync. Large inventories are unbounded in
memory, and even list-only requests currently fetch the full inventory.
