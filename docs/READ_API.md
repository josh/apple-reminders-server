# GraphQL read API

```sh
curl http://127.0.0.1:8081/graphql -H 'Content-Type: application/json' \
  --data '{"query":"{ lists(limit: 10) { totalCount items { id name } pageInfo { hasNextPage } } }"}'
```

The [schema reference](reminders.graphql) reflects the implemented surface.
Live introspection is authoritative for the running version:

- `accounts`, `account(id:)`, `lists`, `list(id:)`, `reminders`, `reminder(id:)`,
  `defaultAccount`, and `defaultList` are available. Accounts are sources owning visible lists.
- Collections provide `items`, `totalCount`, and `pageInfo` with limit/offset.
- Reminder fields include identity, name/body, completion, priority, timestamps,
  and location. List fields include identity, name, subscription, and content
  modification capability, list editability, and sRGB color (`#RRGGBBAA`).
- `reminders(filter: {listIds, completed, nameContains, priorities, dueStatus, dueOnOrAfter, dueBefore}, orderBy, limit, offset)` filters by list IDs, completion, and case-insensitive title substring before pagination. Empty title searches match all items. The default order is identifier ascending. Priority ordering uses numeric values (including zero), and an empty priority filter matches nothing. Priorities must be 0–9. `DueStatus` is `OVERDUE`, `TODAY`, `FUTURE`, `UNSCHEDULED`, or `UNKNOWN`.
- Reminder `listId`, `url`, `startDateComponents`, and `dueDateComponents` are exposed. Component dates preserve calendar/time zone and each optional EventKit component, including floating/date-only values.
- `rawAlarms` preserves absolute date, relative offset, proximity and structured location. `alarms` uses the `AbsoluteAlarm | RelativeAlarm | LocationAlarm` union. `recurrenceRules` preserves frequency, calendar identifier, interval, weekday/ordinal and numeric calendar selectors, plus an optional recurrence end. Rules are read as stored; future occurrences are not expanded.
- Relationships expose account lists/reminders, list account/reminders/summary, and reminder list. Nested search intersects the parent's scope with explicit filters; lists default to identifier order. Summaries count the entire list independently of search pagination.
- `defaultAccount` is the accessible default list's account, not a separate Reminders app preference. Missing IDs and unavailable defaults return null.
- `dueDay` is a nullable reporting day. Inclusive `dueOnOrAfter` and date-only exclusive `dueBefore` use valid Gregorian YYYY-MM-DD bounds; bounded searches omit reminders without a classifiable day. See [READ_API.md](READ_API.md) for time zone and calendar semantics.

Each GraphQL execution lazily loads one plain inventory, cached by a request actor as a Task. Aliases and nested fields reuse its success or error. Concurrent HTTP requests have independent caches; introspection does not touch Reminders. This is a best-effort EventKit snapshot, not an atomic database transaction. Flag enrichment has its own lazy lookup and can observe later state.

`flagged` is resolved lazily by the GraphQL executor. Queries that neither select
it nor filter on it use EventKit alone. Skipped fields (`@skip`, `@include`,
including variables), unselected operations, empty results, and missing reminders
do not trigger AppleScript unless a flag filter is evaluated. A `flagged` filter
requires enrichment even for count-only selections. One request actor shares the
lookup's success or failure across filters, items, and root aliases. A field read
failure sets selected nullable `flagged` fields to null with errors; a filter read
failure fails the collection field rather than returning misleading counts.
MCP reminder tools enrich flags; metrics use EventKit only.

## Fields and search

- `dueDate` and `startDate` return UTC timestamps only for timed component dates.
  `allDayDueDate` and `allDayStartDate` return date-only values only for all-day
  component dates. The alternative representation is null. Source dates remain
  in their own zone; floating dates use the host zone. Unsupported calendars,
  incomplete components, and clock-gap dates produce nullable field errors.
- `timeZone` returns the component time zone, or null for floating dates. Different
  start/due zones, including one floating and one zoned, produce a field error;
  inspect the raw component fields in that case.
- `recurrence` exposes frequency and weekday enums, nullable weekday ordinals,
  calendar selectors, and `end { until count }`. Zero weekday ordinals become
  null and empty constraints become null. No rule means null; multiple rules or
  an unknown frequency produce a field error. Its runtime types are
  `ReminderRecurrence`, `ReminderRecurrenceDay`, and `ReminderRecurrenceEnd` for the
  normalized projection. `recurrenceRules` exposes the separate raw types.
- `lists(filter: {query, accountIds, allowsContentModifications, subscribed},
  orderBy: {direction})` supports case-insensitive name search and ordering.
  The same inputs apply to `Account.lists`.
- Reminder filters support `query` (name or notes), `accountIds`, `flagged`, and
  `hasDueDate`. All filters intersect; empty ID arrays match nothing.
- `dueFrom` is an inclusive RFC 3339 timestamp. `dueBefore` accepts an exclusive
  timestamp or a calendar-day string. Timestamp bounds compare timed
  deadlines as instants and all-day deadlines at midnight in their source zone
  (host zone for floating dates). Do not mix timestamp and calendar-day bounds.
  Equal or reversed bounds are rejected, and undated reminders are excluded.
  `dueBefore` uses a `String` input for either representation.
- `orderBy: {field, direction}` applies at every reminder collection. Fields are
  `NAME`, `DUE_DATE`, `PRIORITY`, `CREATION_DATE`, `MODIFICATION_DATE`, and
  `COMPLETION_DATE`. Direction defaults to `ASC`. Names compare case-insensitively,
  dates chronologically, and priorities numerically. Nulls sort last in both
  directions; ties use ID ascending. Without `orderBy`, the server keeps ID ordering.

## Automation metadata and alarms

`ReminderList.emblem` returns the icon-name string displayed beside the list.
It is separate from the list color and is not an image or a promise of a portable
SF Symbols identifier. `Reminder.remindMeDate` returns the application's alert
date, independently of the deadline and stored EventKit alarm collection.
Absent values are null; failed reads are field errors.

Both `container` unions resolve actual application references. Lists can
refer to accounts or lists; reminders can refer to lists or parent reminders.
Identifiers are validated and joined to the accessible EventKit inventory,
without matching names. A container outside that inventory (including a list
group not exposed by EventKit) returns null with a field error. Parent references
do not imply a children enumeration feature.

These properties each have a lazy per-request bulk read, with success and failure
cached across aliases. They do not read flags. Unselected/skipped properties do
not perform their corresponding automation read. Each script checks identifiers
before and after collection; the reads still are not atomic snapshots.
The script timeout is per Apple event, not a total request deadline.

`alarms` returns a discriminated union. Use inline fragments:

```graphql
{
  reminders(limit: 10) {
    items {
      id
      alarms {
        __typename
        ... on AbsoluteAlarm { at }
        ... on RelativeAlarm { offsetSeconds }
        ... on LocationAlarm {
          geofence { title latitude longitude radiusMeters proximity }
        }
      }
    }
  }
}
```

`rawAlarms` (type `EventKitAlarm`) exposes the stored fields. Combined or incomplete alarm
triggers that the union cannot represent fail the nullable `alarms` field instead
of losing information. `rawAlarms` remains readable for diagnosis.

Accounts without accessible lists and the application's independent
default-account preference are not exposed. Reminder create/update/delete mutations are available for editable lists; see [WRITES.md](WRITES.md). List CRUD and show-in-Reminders actions are also implemented.
