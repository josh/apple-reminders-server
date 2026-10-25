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

Use `tools/list` for the sixteen tools and their input/output JSON Schemas.
The [catalog reference](mcp-tools.json) is an export of that result body without
the JSON-RPC envelope, not a connection configuration file. Tool annotations are
hints, not permission enforcement.

## Results and search

Search criteria follow the GraphQL filter and order rules in the
[schema](reminders.graphql), except that due statuses are lowercase. Missing
single-object lookups return null.

Read tools never use Reminders automation, so they never need Automation
permission or fail on it; MCP clients cannot deselect fields. Flags, alert
dates, container references, and list emblems are not part of MCP results; read
them through [GraphQL](GRAPHQL.md), which exposes
them per selected field. `reminders_create`/`reminders_update` still write
`flagged` and `remindMeDate`, and `lists_create`/`lists_update` still write
`emblem`; a reminder write result echoes the `flagged` value it applied.

A cursor is the next page's offset as a string. It is not bound to the search
criteria: changing the filter, ordering, or limit while reusing a cursor shifts
the page silently, so keep them unchanged. The selected sort with identifier
tiebreaking makes unchanged reminders deterministic, but each page reads live data
rather than a snapshot, so concurrent changes can cause omissions or repeats.

Projection failures fail the tool call.

## Writes

Write tools follow the GraphQL input rules in the [schema](reminders.graphql),
except that optional inputs, including nested ones, must be omitted rather than
null.

## Errors

Successful calls include `structuredContent` and matching JSON text. Tool errors
set `isError: true` and return `{"error": {"code": "...", "message": "..."}}` as
text without `structuredContent`, using the GraphQL
[error codes](GRAPHQL.md#errors-and-partial-saves). When a write is saved but its
result cannot be produced, the error is `WRITE_APPLIED` with the saved ID;
refetch it with `reminders_get` or `lists_get`.
