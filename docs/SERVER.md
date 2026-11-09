# Server

Requires macOS 14+. Serves `POST /graphql`, `POST /mcp`, and `GET /metrics`.
`swift build -c release` produces `.build/release/apple-reminders-server`.

## Setup

launchd owns the sockets and starts the server on connection, including after
exit. Direct launch is refused. Use absolute executable/socket paths (`~` is not
expanded); Unix socket paths have a 104-byte limit. Adjust this LaunchAgent to
the installed binary and user, and create its socket directory:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.github.josh.apple-reminders-server</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/apple-reminders-server</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>REMINDERS_REQUEST_ACCESS</key><string>1</string>
  </dict>
  <key>Sockets</key><dict>
    <key>Listeners</key><dict>
      <key>SockPathName</key><string>/Users/you/Library/Application Support/apple-reminders-server/server.sock</string>
      <key>SockPathMode</key><integer>384</integer>
    </dict>
  </dict>
</dict></plist>
```

Save as `~/Library/LaunchAgents/com.github.josh.apple-reminders-server.plist`, then load:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.github.josh.apple-reminders-server.plist
```

The executable embeds `NSRemindersFullAccessUsageDescription` and
`NSAppleEventsUsageDescription` in its `__TEXT,__info_plist` section. Native access
stays in this process so authorization belongs to the executable launchd runs.

`REMINDERS_REQUEST_ACCESS=1` requests missing full Reminders access at startup;
reads never request it. There is no native read-only grant. While authorization
is pending, `/graphql` and `/mcp` return 503; metrics remain available. Denial or
authorization failure exits the process. Writes honor native editability.
Apple events may prompt separately for Automation permission; MCP reads and
metrics do not need it.

## Sockets

At least one `Sockets` label is required; each may hold multiple sockets. Use
`SockPathName`/`SockPathMode` for Unix or `SockNodeName`/`SockServiceName` for TCP.
Only `TailscaleServe` checks grants; other labels grant fixed access. Excluded
endpoints or missing grants return 403.

| Label            | Access                                                             |
| ---------------- | ------------------------------------------------------------------ |
| `Listeners`      | All endpoints, including writes. Restrict who can connect.         |
| `Metrics`        | `/metrics` only.                                                   |
| `GraphQL`        | `/graphql`, including writes.                                      |
| `MCP`            | `/mcp`, including writes.                                          |
| `TailscaleServe` | Checks `Tailscale-App-Capabilities` for the configured capability. |

For `TailscaleServe`, use `SockNodeName=127.0.0.1` and `SockServiceName=8172`:

```sh
tailscale serve --bg --https=443 --accept-app-caps=example.com/cap/reminders http://127.0.0.1:8172
```

Capability grants are a list of objects mapping `graphql`/`mcp` to `r` or `rw`,
and `metrics` to `r`, under the configured capability key:

```json
{
  "example.com/cap/reminders": [{ "graphql": "r", "mcp": "rw", "metrics": "r" }]
}
```

Combine grants using the greatest access per endpoint; omitted endpoints get none.
Unknown API names/levels, `metrics: "rw"`, malformed headers, or headers over
16 KiB deny access. Accept plain JSON or RFC 2047 UTF-8 Q-encoded header values.
Only a trusted Tailscale Serve proxy may reach this socket: the header is its
assertion of identity and access, not a credential the server verifies independently.

Tailscale builds supporting Unix sockets can instead use
`SockPathName` with a `unix:<path>` target; the Mac App Store build cannot.
No built-in authentication or TLS beyond socket access: keep direct sockets private
and use Tailscale Serve remotely.

## Configuration

Configuration comes only from the plist's `EnvironmentVariables`. Invalid values
prevent startup; other environment variables are ignored.

| Variable                             | Default      | Value                                                                        |
| ------------------------------------ | ------------ | ---------------------------------------------------------------------------- |
| `REMINDERS_REQUEST_ACCESS`           | Off          | `1` to request Reminders access.                                             |
| `REMINDERS_TAILSCALE_APP_CAPABILITY` | None         | `domain/path`; required for `TailscaleServe`.                                |
| `REMINDERS_ALLOWED_ORIGINS`          | None         | Space-separated `http(s)://host[:port]` origins.                             |
| `REMINDERS_EXIT_WHEN_IDLE_SECONDS`   | Stay running | 1–86400 seconds without open connections.                                    |
| `REMINDERS_LOG_LEVEL`                | `info`       | Minimum: `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`. |
| `REMINDERS_METRICS_INTERVAL_SECONDS` | `3600`       | Delay after collection, 1–604800 seconds.                                    |

## HTTP

HTTP/1.1 supports concurrent requests, keep-alive, and chunked bodies. JSON POSTs
require `Content-Type: application/json` (415 otherwise). Bodies over 1 MiB,
including chunked uploads, receive 413.

Host is not validated. An unlisted `Origin` receives 403; allowed origins receive
CORS headers and OPTIONS preflight support. Configured origins cannot contain
paths, queries, fragments, or credentials; default ports are removed.
Repeated `Origin`, `Content-Type`, or `Tailscale-App-Capabilities` headers return
400 rather than choosing a value.

## Deadlines and recovery

GraphQL/MCP handlers have a 60-second deadline after the body is collected.
Expiry cancels their task and returns 504 without waiting for it to finish.
Cancellation cannot interrupt a synchronous native call or undo a save, so work
may finish after the timeout. Refetch before retrying writes.

An independent watchdog checks the main actor every 10 seconds and exits with
status 1 after more than 120 seconds without a heartbeat. This lets launchd recover
from native calls that block the actor; an HTTP deadline alone cannot free it.
Idle exit counts open connections, including keep-alive connections, rather than
time since the last request. Native fetch and automation limits are described in
[EventKit](EVENTKIT.md#reads) and [Reminders automation](APPLESCRIPT.md#writes).

## Errors

| Code                    | Meaning                                                                       |
| ----------------------- | ----------------------------------------------------------------------------- |
| `INVALID_ARGUMENT`      | Invalid input; nothing saved.                                                 |
| `NOT_FOUND`             | Object missing or inaccessible.                                               |
| `READ_ONLY`             | List does not allow the change.                                               |
| `UNSUPPORTED`           | Stored value cannot be represented.                                           |
| `UNSUPPORTED_OPERATION` | Requested change cannot be stored.                                            |
| `LIST_NOT_EMPTY`        | Deleting a nonempty list requires `allowNonEmpty`.                            |
| `WRITE_FAILED`          | Save failed; message includes the native error code. Refetch before retrying. |
| `WRITE_APPLIED`         | Saved, but a later step failed; message includes the saved ID.                |
| `SHOW_APPLIED`          | Navigation succeeded, but the response failed.                                |
| `SHOW_FAILED`           | Navigation failed; the UI may have changed.                                   |
| `INTERNAL`              | Unexpected failure.                                                           |

On `WRITE_APPLIED`, inspect the saved ID and apply only missing changes.
Check existing data before retrying a create after a timeout or lost connection.
Writes have no transaction spanning all steps, rollback, or idempotency key.

## Limits

Accounts come from accessible lists; the default account comes from the default
list. Reads are not atomic across the database and do not prove complete cloud
sync. IDs can change after full sync.
