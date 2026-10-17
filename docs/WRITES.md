# Mutation API

GraphQL and MCP support reminder/list creation, updates, deletion, and UI
navigation. Writes require native authorization and editable lists. Reminder
moves are unsupported. See the [GraphQL schema](reminders.graphql) and
[MCP catalog](mcp-tools.json) for input and output shapes.

## Supported inputs

Creation requires `name` and accepts `listId`, `body`, `priority`, `location`,
`url`, `dueDate`, `allDayDueDate`, `startDate`, `alarms`, `recurrence`,
`timeZone`, `flagged`, and `remindMeDate`. Omitted
`listId` uses the EventKit default list.
Reminders are initially incomplete. Missing optional fields use native defaults.
GraphQL treats explicit null optional creation values as omitted; MCP rejects
explicit null and requires omission.

Updates accept those reminder properties except `listId`, plus `completed`, `completionDate`, and
`clearFields`. Omitted properties are unchanged. Explicit null patch values and
empty patches are rejected. Names cannot be blank; an empty body removes notes.
Priority must be an integer from 0 through 9. URLs must be absolute and contain
no whitespace. `completed: true` sets the completion date through EventKit;
`false` reopens the reminder and clears that date.

`clearFields` supports `LOCATION`, `URL`, `DUE_DATE`, `ALL_DAY_DUE_DATE`,
`START_DATE`, `ALL_DAY_START_DATE`, `COMPLETION_DATE`, `RECURRENCE`,
`TIME_ZONE`. Date alternatives clear the same stored
start or due value. Duplicate entries, clearing both alternatives, or setting and
clearing the same property are invalid. The array alone must contain at least
one entry to form a nonempty patch. Although `clearFields` is nullable in the schema, explicit null is rejected.

Timed and date-only due alternatives cannot be supplied together. Timestamps require
an explicit UTC offset and are stored as Gregorian components in UTC; all-day
dates are floating Gregorian dates. Date strings are validated before native
calls. `allDayStartDate` is recognized but rejected with `UNSUPPORTED_OPERATION`:
Reminders can convert it into timed midnight. Use
an explicit `startDate` until date-only start storage can be preserved reliably.
The resulting start cannot be later than the resulting due date, including
an unchanged counterpart already stored on the reminder. Date changes may affect
native alerts; inspect the returned state.

Setting `completionDate` marks a reminder completed. Clearing it reopens the
reminder. A patch cannot combine `completed` with setting or clearing
`completionDate`, or set and clear `completionDate` together.

`alarms` replaces the complete collection; `[]` removes all alarms. Each input
chooses exactly one of `absoluteDate`, `relativeOffsetSeconds`, or `geofence`.
A geofence requires finite latitude/longitude, nonnegative radiusMeters, and
`ARRIVE` or `DEPART` proximity; title is optional. Relative offsets must be finite
and require a start date on the resulting reminder, including when clearing an
existing start date. Storage does not guarantee alert delivery.

`recurrence` replaces the complete recurrence-rule collection with one rule.
Omission preserves the existing rules; `clearFields: [RECURRENCE]` removes them.
Daily, weekly, monthly and yearly frequencies require a positive `interval`.
An optional `end` chooses exactly one inclusive `until` timestamp or positive
occurrence `count`; omission means no specified end. Interval and count are
limited to 1...2147483647 consistently across both APIs.

Weekday selectors support weekly, monthly and yearly rules. Ordinals are allowed
only for monthly/yearly rules: monthly ordinals range from -5 to 5, yearly from
-53 to 53, excluding zero. Omit the ordinal to select every matching weekday.
`daysOfMonth` requires monthly frequency; `monthsOfYear`, `weeksOfYear`, and
`daysOfYear` require yearly frequency. `setPositions` requires another selector.
Selector arrays must be nonempty and unique; zero and out-of-range values are
rejected. Ordinal weekdays cannot be combined with `weeksOfYear`. Invalid
combinations are rejected before constructing EventKit objects. Nested optional
GraphQL nulls mean omission; MCP requires omission instead of null.

For example, `{frequency: MONTHLY, interval: 1, daysOfWeek: [{day: FRIDAY,
ordinal: -1}]}` repeats on the last Friday each month. This writes the stored
rule; it does not expand future occurrences or guarantee delivery. Completing
recurring reminders may create provider-managed follow-up instances; the server
does not control that behavior.

`timeZone` accepts an IANA zone identifier (or `UTC`) and applies to both resulting
start and due components. Timed values keep their instant and are represented in
the chosen zone; date-only values keep their calendar day. `TIME_ZONE` clearing
converts timed values to host-local wall time and removes their explicit zone.
A zone change requires at least one resulting start or due date; zones are not
stored independently of date components. Existing non-Gregorian or unresolvable
dates are rejected. Without a zone change, new timed inputs use UTC.

`flagged` writes the native flag independently of priority. `remindMeDate` writes
the application's alert date using typed Apple-event date arguments. It can also change the timed deadline, start components, zone, and alarms;
inspect the resulting state. It is not an independent EventKit alarm setter. It cannot
be combined with `alarms`, or with start, due, or time-zone changes in the same request, because Reminders
may overwrite those components. `REMIND_ME_DATE` clearing is not supported:
AppleScript rejects a missing date, and removing
EventKit alarms alone leaves this property intact. Unsupported clearing is
rejected before saving. See [automation handlers](APPLESCRIPT.md#handlers-and-identity).

## Example

Use an explicitly chosen editable list ID as `$listId`:

```graphql
mutation CreateReminder($listId: ID!) {
  createReminder(input: {
    listId: $listId
    name: "Try the mutation API"
    body: "Example reminder"
    priority: 5
    allDayDueDate: "2030-01-02"
  }) {
    id
    name
    completed
    allDayDueDate
    list { id }
  }
}
```

```graphql
mutation Complete($id: ID!) {
  updateReminder(id: $id, patch: {completed: true}) {
    id
    completed
    completionDate
  }
}
```

```graphql
mutation Delete($id: ID!) {
  deleteReminder(id: $id) { deletedId }
}
```

## MCP operations

`reminders_create` takes creation properties directly in `arguments`.
`reminders_update` takes `{id, patch}`; `reminders_delete` takes `{id}`.
Both interfaces share transport-neutral input validation and the same typed
native write operations. MCP optional inputs must be omitted rather than null,
including nested inputs; GraphQL retains its documented null rules.

Successful create/update tools return `{reminder}` with the complete MCP read
projection. Delete returns `{deletedId}`. Each success includes structuredContent
and matching JSON text. Validation and execution failures use `isError: true`
without structuredContent. Discovery marks all three tools as writes and
non-idempotent; update/delete also carry the destructive hint.

## Execution and errors

Writes run on the same serialized worker queue and main-thread native guard as
reads. Each mutation owns an EventKit store, fetches or creates its object in
that store, checks list editability, validates the resulting state, then commits
one save or delete. Flag and alert-date changes also use in-process Reminders
automation after the EventKit save. Automation/refetch and response-enrichment
failures follow the [outcome table below](#client-handling-after-a-save).

A GraphQL operation's root mutations execute serially. Request inventory and
lazy automation caches are invalidated after each native mutation attempt, so
later mutation fields and nested reads do not reuse a pre-write snapshot.

Missing update/delete IDs return `NOT_FOUND`; deletion is not silently successful
for a missing ID. Input failures use `INVALID_ARGUMENT`; list-capability
failures use `READ_ONLY`. Native failures use `WRITE_FAILED` with an EventKit code.
These are message prefixes, not structured error-code extensions.

## List mutations

GraphQL exposes `createList(input:)`, `updateList(id:, patch:)`, and
`deleteList(id:, allowNonEmpty: false)`. MCP exposes `lists_create`,
`lists_update`, and `lists_delete`. Creation requires a name and explicit account
ID. Updates accept name, color and emblem; nulls, blank names/emblems, and empty
patches are rejected. Colors accept opaque sRGB `#RRGGBB` or `#RRGGBBFF`; other alpha values
are rejected because Reminders normalizes them to opaque. Emblems are
native icon names whose acceptance depends on Reminders.

Immutable, subscribed and non-editable lists are rejected for updates/deletion.
Deletion first checks for reminders unless `allowNonEmpty` is explicitly true;
that option deletes the list and its contents. The check and delete are not an
atomic lock against edits by other processes. Missing list IDs are errors.
Emblem changes run after the EventKit save. Successful MCP writes enrich the
saved list before returning.

## Show actions

`showReminder`/`showList` and `reminders_show`/`lists_show` change Reminders' UI,
without saving objects. Missing IDs fail before navigation. MCP discovery marks
these actions non-read-only and nondestructive. A post-navigation enrichment
failure is `SHOW_APPLIED`; other navigation failures can still leave the UI
changed and are reported as `SHOW_FAILED`.

## Synchronization retries

Reminder automation retries transient missing-object/cannot-set errors at most
30 times with 0.1-second delays. Setters may repeat if a later automation read
fails. Each attempt targets the same saved reminder and expected list.

Newly saved EventKit lists can take several seconds to appear in Reminders' scripting inventory. MCP list enrichment retries missing
inventory entries at most 16 times, two seconds apart. Permission, scripting,
and projection errors fail immediately. A present null emblem is a valid value,
not a reason to retry. Emblem writes retry only transient missing-object and
cannot-set errors on the same list ID, at most 30 attempts one second apart.
Neither path repeats list creation. Apple-event execution adds to these waits;
they are not hard request deadlines. Exhaustion still reports an error, including
`WRITE_APPLIED` when a preceding save succeeded.

## Client handling after a save

An HTTP success status does not establish mutation success: inspect the API body.
These cases apply to reminder and list create/update operations:

| Outcome | Response | Client action |
| --- | --- | --- |
| Backend automation/refetch fails after an EventKit save | GraphQL root mutation is null with a `WRITE_APPLIED` error and saved ID in its message. MCP returns `isError: true`, with the saved ID in text and no `structuredContent`. | Retain the saved ID, inspect its current state, and reconcile only the changes still needed. Never repeat creation automatically. |
| GraphQL response metadata fails after a successful mutation | The saved object can remain in `data`, including a selected `id`, while a nullable field is null with an error path pointing to that field. | Always select `id` on writes. Preserve it even when `errors` is present. The field error does not mean the write failed. |
| MCP response enrichment fails after a successful mutation | `WRITE_APPLIED` tool error with saved ID; no partial success payload. | Refetch the saved ID. If the same metadata read still fails, a complete MCP read may remain unavailable; inspect the item in Reminders before deciding on a retry. |
| Timeout, lost connection, or unclassified error | The client may have no saved ID or confirmed outcome. | Treat the outcome as unknown, not as evidence that no write occurred. Inspect existing data before retrying a create. |

A post-save failure may mean that none, some, or all requested automation fields
were applied. There is no transaction spanning EventKit and Reminders automation,
no automatic rollback, and no creation idempotency key. Error codes and saved IDs
are currently message text, not structured error fields; clients should preserve
the full diagnostic rather than assuming a stable message grammar. Retrying a
read is safe for data, but does not resolve a persistent Automation permission
failure. A minimal read that avoids automation can recover stored fields while
metadata remains unavailable.
