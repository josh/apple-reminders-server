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
hints, not permission enforcement. [Writes and navigation](WRITES.md) describe
mutation semantics and partial-save handling.

## Results and search

Search tools return `{items, totalCount, nextCursor?}`. Limits default to 50
(1–100). Filters intersect; empty ID/priority arrays match nothing. Query matches
a case-insensitive name-or-notes substring for reminders, or names for lists.
Empty text imposes no restriction. Priorities are integers 0–9; due statuses are
lowercase. Missing single-object lookups return null. Accounts derive from
accessible lists, and the default account is the default list's account.

Read tools make one EventKit read and never use Reminders automation, so
MCP clients, which cannot deselect fields, are not delayed or failed by Reminders'
scripting interface. Flags, alert dates, container references, and list emblems
are not part of MCP results; read them through [GraphQL](READ_API.md#automation-metadata-and-alarms),
which exposes them per selected field. `reminders_create`/`reminders_update`
still write `flagged` and `remindMeDate`, and `lists_create`/`lists_update` still
write `emblem`, through automation after the EventKit save; a reminder write result
echoes the `flagged` value it applied. Optional inputs must be omitted rather than null.

A cursor is the next page's offset as a string. It is not bound to the search
criteria: changing the filter, ordering, or limit while reusing a cursor shifts
the page silently, so keep them unchanged. The selected sort with identifier
tiebreaking makes unchanged reminders deterministic, but each page reads live data
rather than a snapshot, so concurrent changes can cause omissions or repeats.

The catalog describes stored and projected fields. Projected dates and recurrence
use explicit nulls when absent; some optional raw fields are omitted, and `flagged`
appears only in write results. Projection failures fail the tool call.

Search criteria belong in `filter`. Reminder `orderBy: {field, direction?}`
supports NAME, DUE_DATE, PRIORITY, CREATION_DATE, MODIFICATION_DATE, and
COMPLETION_DATE with ASC/DESC ordering. List `orderBy: {direction?}` orders by
name. Direction defaults to ASC. Nulls sort last in both directions and ties use
ID ascending. Without `orderBy`, results use ID ascending. Keep filters,
ordering, and limit unchanged across pages.

`dueFrom` and timestamp `dueBefore` bound deadline instants inclusively and
exclusively, respectively. All-day deadlines use midnight in their source time
zone. `dueOnOrAfter` and date-only `dueBefore` bound reporting days. Bounds cannot
mix modes.

## Errors

Successful calls include `structuredContent` and matching JSON text. Tool errors
set `isError: true` and return `{"error": {"code": "...", "message": "..."}}` as
text without `structuredContent`. [Writes](WRITES.md#execution-and-errors) list
the codes and the [write outcomes](WRITES.md#client-handling-after-a-save) for
failures after a save. Protocol errors are handled by the SDK.
