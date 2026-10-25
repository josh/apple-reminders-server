# MCP API

`POST /mcp` accepts individual JSON-RPC 2.0 messages using MCP protocol
`2025-11-25`. It supports `initialize`, `ping`, `tools/list`, `tools/call`, and
accepted notifications (HTTP 202). It is stateless: no session header, SSE stream,
server requests, or resumability. GET returns 405. Use `Content-Type:
application/json` and `Accept: application/json, text/event-stream`; include
`MCP-Protocol-Version: 2025-11-25` after initialization.

```sh
curl http://127.0.0.1:8171/mcp -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}'
```

Use `tools/list` for the sixteen tools, their descriptions, and their input and
output JSON Schemas; the [catalog reference](mcp-tools.json) is an export of that
result body. Tool annotations are hints, not permission enforcement. Read tools
never use Reminders automation, so they never need Automation permission.

## Errors

Successful calls include `structuredContent` and matching JSON text. Tool errors
set `isError: true` and return `{"error": {"code": "...", "message": "..."}}` as
text without `structuredContent`. [SERVER.md](SERVER.md#errors) lists the codes.
