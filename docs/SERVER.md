# HTTP server

The server runs on macOS 14+ and exposes `POST /graphql`, `POST /mcp`, and
`GET /metrics` on `127.0.0.1`.

Reminder and list writes honor EventKit authorization and editability. See
[GraphQL API](GRAPHQL.md) for supported inputs and failures after a save.

## Startup options

Startup options are the only configuration interface;
environment-variable configuration is not supported.

| Option | Default | Behavior |
| --- | --- | --- |
| `--port` | `8171` | Loopback listener port, 1–65535 |
| `--metrics-interval-seconds` | `3600` | Delay after each metrics collection, 1–604800 seconds |
| `--log-level <level>` | `info` | Minimum log level: `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical` |
| `--allowed-origin <origin>` | None | Repeatable additional browser origin, `http(s)://host[:port]` |
| `--tailscale-app-capability <name>` | Off | Authorize by Tailscale Serve app capabilities; a proxied request without them is refused |
| `--request-access` | Off | Explicitly request EventKit access at startup |
| `--help`, `-h` | — | Show usage |

## Permissions and execution

Permissions are granted to the server executable. EventKit permission is
requested only through the explicit startup option, not in response to a read.
EventKit grants full reminder access rather than a read-only grant. Automation
permission is separate and may be requested when an operation first sends Apple
events to Reminders. Metrics collection never needs Automation permission.

Permission attribution and persistence depend on the executable's signing and
launch context.

## HTTP behavior

The server speaks HTTP/1.1 with concurrent requests, keep-alive, and chunked
request bodies, and shuts down gracefully on SIGINT or SIGTERM.

Host is not validated; run network access through a trusted proxy such as
Tailscale Serve. Origin, when present, must be `http://localhost:<port>`,
`http://127.0.0.1:<port>`, or an origin given by `--allowed-origin`; other
origins return 403. Allowed origins receive CORS headers and OPTIONS preflight
support. Origins must have no path, query, fragment, or credentials, and a
default port is dropped. With `--tailscale-app-capability`, a request that
arrives through a proxy must carry the capability header; use the option only
behind Tailscale Serve. JSON POSTs require `Content-Type: application/json`;
other media types return 415. Request bodies are limited to 1 MiB, including
chunked uploads; excess returns 413.

There is no built-in identity authentication or TLS, so keep the service local
or put it behind a trusted proxy with its own access controls. GraphQL
subscriptions are not implemented.

## Errors

GraphQL and MCP errors carry the same codes. GraphQL reports the code in
`extensions.code`; MCP reports it in the tool error payload.

| Code | Meaning |
| --- | --- |
| `INVALID_ARGUMENT` | Input failed validation; nothing was saved. |
| `NOT_FOUND` | The object does not exist or is not accessible. |
| `READ_ONLY` | The list does not allow the change. |
| `UNSUPPORTED` | A stored value cannot be represented in the response. |
| `UNSUPPORTED_OPERATION` | Reminders cannot store the requested change. |
| `LIST_NOT_EMPTY` | The list has reminders; deleting it needs `allowNonEmpty`. |
| `WRITE_FAILED` | EventKit refused the save; the message includes its code. |
| `WRITE_APPLIED` | The save succeeded but a later step failed; the message names the saved ID. |
| `SHOW_APPLIED` | Navigation happened but the response could not be built. |
| `SHOW_FAILED` | Navigation failed and may still have changed the UI. |
| `INTERNAL` | An unexpected server error. |

## Limits

Accounts are derived from accessible reminder lists. The default account is
inferred from the default list. Reads are not atomic across the
Reminders database, and accessible records do not establish complete cloud synchronization.
Identifiers may change after a full sync.
