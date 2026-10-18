# GraphQL read API

```sh
curl http://127.0.0.1:8171/graphql -H 'Content-Type: application/json' \
  --data '{"query":"{ lists(limit: 10) { totalCount items { id name } pageInfo { hasNextPage } } }"}'
```

The [schema](reminders.graphql) lists fields and inputs; live introspection is
authoritative. Collections return `items`, `totalCount`, and `pageInfo` with
limit/offset pagination. Nested searches intersect the parent's scope; list
summaries count the whole list independently of pagination.

Accounts derive from accessible lists; `defaultAccount` is the default list's
account. Missing IDs and unavailable defaults return null. Each execution lazily
shares one EventKit inventory across aliases and nested fields, including cached
failures. Requests have independent inventories; introspection does not read data.

## Search

Filters intersect. Empty ID or priority arrays match nothing; empty text matches
all. `query` searches names/notes case-insensitively; `nameContains` searches only
reminder names. Priorities must be 0–9. Due status includes `UNKNOWN` for
unclassifiable components and is independent of completion; combine with
`completed: false` for outstanding work.

`orderBy` defaults to ascending direction; omission preserves ID order. Names
compare case-insensitively, dates chronologically, and priorities numerically.
Nulls sort last in either direction; ties use ID ascending. The same filters and
ordering apply to nested collections.

`dueOnOrAfter` and date-only `dueBefore` are inclusive/exclusive reporting-day
bounds in Gregorian YYYY-MM-DD. `dueDay` uses the host zone for timed dates and
preserves all-day calendar dates; unclassifiable values are null.
`dueFrom` and timestamp `dueBefore` bound instants. All-day deadlines use midnight
in their source zone (host zone if floating). Bounds cannot mix modes; equal or
reversed bounds are rejected. Bounded searches exclude undated/unclassifiable
values. See [deadline classification](METRICS.md#deadline-classification).

## Dates and stored values

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

## Automation metadata and alarms

`flagged`, `emblem`, `remindMeDate`, and containers each use a separate lazy bulk
read, caching success or failure within the request. Unselected/skipped fields,
empty results, and missing IDs avoid those reads. A flag filter requires flag
enrichment even for count-only queries. Field failures produce nullable-field
errors; filter failures fail the collection. Selecting no automation fields or
filters uses EventKit alone.

```graphql
{ reminders { totalCount items { id name } } }
{ reminders { items { id name flagged } } }
```

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

See [automation](APPLESCRIPT.md) for identity validation and read consistency.

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

Raw alarm and recurrence collections are empty arrays when absent. Stored rules
are not expanded into future occurrences. Raw weekdays use Sunday = 1; zero
first weekday is unset, and signed ordinals are preserved. Alarm offset zero
alone does not distinguish absolute and relative triggers. See [writes](WRITES.md)
for mutations and UI navigation.
