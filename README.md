# apple-reminders-server

A Swift HTTP server for reading and changing Apple Reminders on macOS through GraphQL
and MCP, with Prometheus metrics for reminder counts. EventKit and Reminders
Apple events run in the server process.

Requires macOS 14+ and Swift 6.4+:

```sh
swift build -c release
./.build/release/apple-reminders-server --request-access
```

Omit `--request-access` once Reminders permission is granted. Automation requires
separate permission when first used. The server listens on `127.0.0.1:8081` and
has no authentication or TLS; it is intended for local use. Add
`--allowed-origin https://app.example` to allow a browser client on another origin.

| Endpoint | Documentation |
| --- | --- |
| `POST /graphql` | [Reads](docs/READ_API.md), [writes](docs/WRITES.md), [schema](docs/reminders.graphql) |
| `POST /mcp` | [MCP](docs/MCP.md), [tool catalog](docs/mcp-tools.json) |
| `GET /metrics` | [Metrics](docs/METRICS.md), [example](docs/metrics.prom) |

See [server configuration and permissions](docs/SERVER.md) and the
[documentation index](docs/README.md).
Source lives in the single executable target `Sources/RemindersServer/`.
