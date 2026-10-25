# HTTP server

The server runs on macOS 14+ and exposes `POST /graphql`, `POST /mcp`, and
`GET /metrics`.

Reminder and list writes honor EventKit authorization and editability. See
[GraphQL API](GRAPHQL.md) for supported inputs and failures after a save.

## Running under launchd

launchd is the only supported way to start the server. A LaunchAgent owns the
listening sockets: launchd starts the server on the first connection, hands it the
sockets, and starts it again after it exits. Run directly, the server refuses to
start. Configuration comes only from the plist's `EnvironmentVariables`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.apple-reminders-server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/apple-reminders-server</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>REMINDERS_TAILSCALE_APP_CAPABILITY</key>
    <string>example.com/cap/reminders</string>
    <key>REMINDERS_EXIT_WHEN_IDLE_SECONDS</key>
    <string>600</string>
  </dict>
  <key>Sockets</key>
  <dict>
    <key>Listeners</key>
    <dict>
      <key>SockPathName</key>
      <string>/Users/you/Library/Application Support/apple-reminders-server/server.sock</string>
      <key>SockPathMode</key>
      <integer>384</integer>
    </dict>
    <key>TailscaleServe</key>
    <dict>
      <key>SockNodeName</key>
      <string>127.0.0.1</string>
      <key>SockServiceName</key>
      <string>8172</string>
    </dict>
  </dict>
</dict>
</plist>
```

Save it as `~/Library/LaunchAgents/local.apple-reminders-server.plist`, create the
socket directory, and load it with
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.apple-reminders-server.plist`.
launchd does not expand `~` inside the plist, and Unix socket paths are limited to
104 bytes.

## Sockets

The keys of the plist's `Sockets` dictionary are labels; the label a request
arrives on decides how it is trusted. Each label may use a Unix socket
(`SockPathName`, with `SockPathMode`) or TCP (`SockNodeName`, `SockServiceName`),
and may list several sockets. Only `TailscaleServe` checks request headers; the
others grant fixed access. At least one label is required.

| Label | Trust |
| --- | --- |
| `Listeners` | The default: full access to every endpoint. Restrict it with the socket file mode or address. |
| `Metrics` | Only `GET /metrics`; other endpoints return 403. |
| `GraphQL` | Only `/graphql`, with write access; other endpoints return 403. |
| `MCP` | Only `/mcp`, with write access; other endpoints return 403. |
| `TailscaleServe` | Requires the `Tailscale-App-Capabilities` grant named by `REMINDERS_TAILSCALE_APP_CAPABILITY`; requests without one get 403. |

Point Tailscale Serve at the `TailscaleServe` socket and forward the capability,
for example
`tailscale serve --bg --https=443 --accept-app-caps=example.com/cap/reminders http://127.0.0.1:8172`.
A Tailscale build that can open Unix sockets can use `SockPathName` and a
`unix:<path>` target instead; the Mac App Store build cannot.

A grant is a list of objects mapping `graphql` and `mcp` to `r` or `rw`, and
`metrics` to `r`.

## Configuration

| Variable | Default | Behavior |
| --- | --- | --- |
| `REMINDERS_TAILSCALE_APP_CAPABILITY` | None | Capability name, `domain/path`; required with a `TailscaleServe` socket |
| `REMINDERS_ALLOWED_ORIGINS` | None | Space-separated browser origins, `http(s)://host[:port]` |
| `REMINDERS_EXIT_WHEN_IDLE_SECONDS` | Stay running | Exit after this many seconds, 1–86400, without open connections |
| `REMINDERS_LOG_LEVEL` | `info` | Minimum log level: `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical` |
| `REMINDERS_METRICS_INTERVAL_SECONDS` | `3600` | Delay after each metrics collection, 1–604800 seconds |
| `REMINDERS_REQUEST_ACCESS` | Off | `1` requests EventKit access at startup |

An invalid value stops the server at startup. Other environment variables are
ignored.

## Permissions and execution

Permissions are granted to the program launchd runs. EventKit permission is
requested only when `REMINDERS_REQUEST_ACCESS` is `1`, not in response to a read.
EventKit grants full reminder access rather than a read-only grant. Automation
permission is separate and may be requested when an operation first sends Apple
events to Reminders. Metrics collection never needs Automation permission.

## HTTP behavior

The server speaks HTTP/1.1 with concurrent requests, keep-alive, and chunked
request bodies.

Host is not validated. Origin, when present, must be listed in
`REMINDERS_ALLOWED_ORIGINS`; other origins return 403. Allowed origins receive
CORS headers and OPTIONS preflight support. Origins must have no path, query,
fragment, or credentials, and a default port is dropped. JSON POSTs require
`Content-Type: application/json`; other media types return 415. Request bodies
are limited to 1 MiB, including chunked uploads; excess returns 413.

There is no built-in authentication or TLS beyond the socket labels; keep
`Listeners` private and reach the server remotely through Tailscale Serve. GraphQL
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
