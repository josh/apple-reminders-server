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

Sixteen tools are advertised with input and output JSON Schemas:

- `accounts_list({})` returns `{items}` containing accounts owning accessible lists.
- `accounts_get({id})` returns `{account}`, null for an absent account.
- `lists_get({id})` returns a list or null.
- `defaults_get({})` returns `{list, account}`, each nullable.
- `lists_summary({listId?})` returns all seven per-list summary counts; unknown IDs yield no items.
- `lists_list({filter?, orderBy?, limit?, cursor?})` returns `{items, totalCount, nextCursor?}`. Filter fields are `query`, `accountIds`, `allowsContentModifications`, and `subscribed`. Query searches names case-insensitively. Empty account IDs match nothing. Limit defaults to 50 (1–100).
- `reminders_search({filter?, orderBy?, limit?, cursor?})` returns `{items, totalCount, nextCursor?}`. Filter fields are `dueFrom`, `accountIds`, `listIds`, `flagged`, `hasDueDate`, `completed`, `query`, `priorities`, `dueStatus`, `dueOnOrAfter`, and `dueBefore`. Query matches a case-insensitive name-or-notes substring; empty means no text restriction. Filters intersect; empty ID or priority arrays match nothing. Priorities are integers 0–9. Due status uses lowercase names (`overdue`, `today`, `future`, `unscheduled`, `unknown`). Limit defaults to 50 (1–100).
- `reminders_get({id})` returns `{reminder}`, with null for an absent identifier.
- `reminders_create`, `reminders_update`, and `reminders_delete` implement reminder writes; see [WRITES.md](WRITES.md).
- `reminders_show({id})` and `lists_show({id})` navigate the Reminders UI and return the enriched object. Discovery marks them non-read-only, nondestructive and idempotent.
- `lists_create({name, accountId, color?, emblem?})`, `lists_update({id, patch})`, and `lists_delete({id, allowNonEmpty?})` implement list CRUD. Opaque colors and Reminders emblems are supported.

Read tools obtain one EventKit inventory. List/default results then read Reminders icons and containers; reminder results read flags, containers, and alert dates. Empty result collections skip metadata reads. Tool discovery and summaries do not require automation. Successful writes refetch their enriched result after saving. Date bounds participate in cursor identity. Optional inputs must be omitted rather than null.

Projected dates, flags, alert dates, recurrence, and list emblems use explicit nulls for absent values; some optional raw stored fields remain omitted. Success includes structured content and matching JSON text. Execution failures use `isError: true`, while the SDK handles protocol errors and initialization.

Opaque random cursor tokens bind the resource type (lists or reminders), all search criteria, and page size, expire after ten minutes, and do not survive restart. An actor protects the cache under concurrent requests. The bounded cache holds up to 1,024 tokens; eviction can invalidate an earlier token. The selected sort with identifier tiebreaking makes a stable inventory deterministic, but each page reads live data: concurrent changes can cause omissions or repeats. Cursors do not represent snapshots.

MCP reminder results include both original date components and `dueDate`,
`allDayDueDate`, `startDate`, `allDayStartDate`, and `timeZone`, using calendar-aware projections. They also include `container: {kind, id}`,
`remindMeDate`, singular `recurrence`, and discriminated `alarms` with
`kind: AbsoluteAlarm | RelativeAlarm | LocationAlarm`. Raw alarm
objects are available under `rawAlarms`; `recurrenceRules` remains available. List results
include `emblem`, `container`, `allowsListModifications`, and `subscribed`, plus
stored fields. Metadata/projection failures fail the tool call;
unknown values are not replaced with successful empty results.

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

Accounts are derived from accessible lists; the default account is inferred from the
default list. Raw stored fields remain available; some absent optional fields are omitted. Reminder writes include recurrence, time zones, flags and alert-date setting. Alert-date clearing and date-only start writes remain unsupported. List CRUD is implemented. No tags, sections, or
attachments are exposed.


## Discovery and errors

[mcp-tools.json](mcp-tools.json) is an export of the implemented `tools/list`
result body, without the JSON-RPC envelope. It is a reference, not client
connection configuration. Use live discovery for the running version's input
schemas, output schemas, and behavioral annotations. Annotations are hints,
not permission enforcement.

Successful calls include `structuredContent` and matching JSON text. Tool errors
set `isError: true` and return diagnostic text without a success payload.
Known post-save failures include `WRITE_APPLIED` and the saved identifier; retain
that identifier and refetch before retrying. Creation has no idempotency key.
See [WRITES.md](WRITES.md) for partial-write and navigation errors.
