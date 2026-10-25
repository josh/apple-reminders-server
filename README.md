# apple-reminders-server

A Swift HTTP server for reading and changing Apple Reminders on macOS through GraphQL
and MCP, with Prometheus metrics for reminder counts. EventKit and Reminders
Apple events run in the server process.

Requires macOS 14+ and Swift 6.4+:

```sh
swift build -c release
./.build/release/apple-reminders-server --request-access
```

Omit `--request-access` once macOS has granted Reminders permission. Automation
asks for its own permission the first time it runs. The server listens on
`127.0.0.1:8171` with no built-in identity authentication or TLS, so keep it to
local use. Add `--allowed-origin https://app.example` to allow a browser client
on another origin.

| Endpoint | Documentation |
| --- | --- |
| `POST /graphql` | [GraphQL](docs/GRAPHQL.md), [schema](docs/reminders.graphql) |
| `POST /mcp` | [MCP](docs/MCP.md), [tool catalog](docs/mcp-tools.json) |
| `GET /metrics` | [Metrics](docs/METRICS.md), [example](docs/metrics.prom) |

Server configuration and permissions are covered in [docs/SERVER.md](docs/SERVER.md),
and [docs/README.md](docs/README.md) indexes the rest of the documentation.

Regenerate the GraphQL schema and MCP tool catalog after changing either:

```sh
swift run apple-reminders-server --dump-graphql-schema >docs/reminders.graphql
swift run apple-reminders-server --dump-mcp-tools >docs/mcp-tools.json
prettier --write docs/reminders.graphql docs/mcp-tools.json
```
