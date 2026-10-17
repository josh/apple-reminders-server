# MCP API

`POST /mcp` accepts individual JSON-RPC 2.0 messages using MCP protocol
`2025-11-25`. It supports `initialize`, `ping`, `tools/list`, `tools/call`, and
accepted notifications (HTTP 202). It is stateless: no session header, SSE stream,
server requests, or resumability. GET returns 405. Use `Content-Type:
application/json` and `Accept: application/json, text/event-stream`; include
`MCP-Protocol-Version: 2025-11-25` after initialization.

```sh
curl http://127.0.0.1:8081/mcp -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}'
```

Use `tools/list` for the sixteen tools and their input/output JSON Schemas.
The [catalog reference](mcp-tools.json) is an export of that result body, without
the JSON-RPC envelope. It is not connection configuration. Tool annotations are
hints, not permission enforcement. [Writes and navigation](WRITES.md) describe
mutation semantics and partial-save handling.

## Results and search

Search tools return `{items, totalCount, nextCursor?}`. Limits default to 50
(1–100). Filters intersect; empty ID/priority arrays match nothing. Query matches
a case-insensitive name-or-notes substring for reminders, or names for lists.
Empty text imposes no restriction. Priorities are integers 0–9; due statuses are
lowercase. Missing single-object lookups return null. Accounts derive from
accessible lists, and the default account is the default list's account.

Read tools obtain one EventKit inventory. List/default results then read Reminders icons and containers; reminder results read flags, containers, and alert dates. Empty result collections skip metadata reads. Tool discovery and summaries do not require automation. Optional inputs must be omitted rather than null.

Opaque random cursor tokens bind the resource type (lists or reminders), all search criteria, and page size, expire after ten minutes, and do not survive restart. The bounded cache holds up to 1,024 tokens; eviction can invalidate an earlier token. The selected sort with identifier tiebreaking makes a stable inventory deterministic, but each page reads live data: concurrent changes can cause omissions or repeats. Cursors do not represent snapshots.

The catalog describes stored and projected fields. Projected dates, flags, alert
dates, recurrence, and emblems use explicit nulls when absent; some optional raw
fields are omitted. Metadata/projection failures fail the tool call.

Search criteria belong in `filter`. Reminder `orderBy: {field, direction?}`
supports NAME, DUE_DATE, PRIORITY, CREATION_DATE, MODIFICATION_DATE, and
COMPLETION_DATE with ASC/DESC ordering. List `orderBy: {direction?}` orders by
name. Direction defaults to ASC. Nulls sort last in both directions and ties use
ID ascending. Without `orderBy`, results use ID ascending. Cursors require
unchanged filters, ordering, and limit.

`dueFrom` and timestamp `dueBefore` bound deadline instants inclusively and
exclusively, respectively. All-day deadlines use midnight in their source time
zone. `dueOnOrAfter` and date-only `dueBefore` bound reporting days. Bounds cannot
mix modes.

## Errors

Successful calls include `structuredContent` and matching JSON text. Tool errors
set `isError: true` and return diagnostic text without a success payload.
Protocol errors are handled by the SDK. See [write outcomes](WRITES.md#client-handling-after-a-save)
for failures after a save.
