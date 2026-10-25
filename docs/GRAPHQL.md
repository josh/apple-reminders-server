# GraphQL API

```sh
curl http://127.0.0.1:8171/graphql -H 'Content-Type: application/json' \
  --data '{"query":"{ lists(limit: 10) { totalCount items { id name } pageInfo { hasNextPage } } }"}'
```

The [schema](reminders.graphql) documents every type, field, and argument; live
introspection is authoritative. This page covers rules that span fields.

## Reads

All fields in one request observe the same data, and a failed read fails every
field that needs it. Missing IDs return null. Nested collections intersect their
parent's scope.

Filters intersect, and empty arrays match nothing. Ordering puts nulls last in
either direction and breaks ties by ID; without `orderBy`, results use ID order.
Calendar-day bounds and `dueDay` place timed dates in the host zone and keep each
all-day date's own calendar day.

A projection that cannot represent the stored value, such as mixed start and due
zones, multiple recurrence rules, or a combined alarm trigger, fails only that
field. The raw fields (`dueDateComponents`, `recurrenceRules`, `rawAlarms`) still
return the stored values.

`flagged`, `emblem`, `remindMeDate`, and `container` come from Reminders
automation and may need Automation permission. A request that selects none of
them and filters on no flag never uses automation. Their failures are field
errors, except a flag filter failure, which fails the collection.

## Mutations

Root mutations run serially, and later fields observe earlier writes. A rejected
mutation changes nothing. Beyond the per-field rules in the schema:

- The resulting start date cannot be later than the due date, and relative
  alarms need a resulting start date.
- A `timeZone` change needs at least one resulting date.
- `completed` cannot be combined with setting or clearing `completionDate`.
- A patch cannot set and clear the same field, or clear both forms of one date.
- `remindMeDate` cannot be combined with date, time-zone, or alarm changes,
  because Reminders may rewrite those in response. It cannot be cleared.
- Recurrence selectors must fit the frequency: weekdays need weekly or longer,
  `daysOfMonth` monthly, the other year selectors yearly, and `setPositions`
  another selector.

## Errors and partial saves

Every error carries a code in `extensions.code`, such as `NOT_FOUND`,
`INVALID_ARGUMENT`, `READ_ONLY`, `UNSUPPORTED_OPERATION`, or `WRITE_FAILED`.

`flagged`, `remindMeDate`, and `emblem` apply through Reminders automation after
the EventKit save, so a write can partly succeed:

| Outcome | Response | Client action |
| --- | --- | --- |
| Automation fails after the save | Null result, `WRITE_APPLIED` error naming the saved ID | Inspect that ID and apply only what is missing; never repeat a create automatically. |
| A response field fails after the save | Selected fields such as `id` remain; the failed field is null with an error | Always select `id` and keep it even when `errors` is present. |
| Navigation fails after showing | `SHOW_APPLIED`, or `SHOW_FAILED` if it may have changed the UI | Treat the UI as possibly changed. |
| Timeout or lost connection | No confirmed outcome | Check existing data before retrying a create. |

There is no transaction across EventKit and automation, no rollback, and no
idempotency key. Saved IDs appear only in error messages.
