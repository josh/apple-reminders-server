# Reminders metrics

`GET /metrics` serves cached EventKit counts in Prometheus text format 0.0.4.
All metrics are gauges. [metrics.prom](metrics.prom) contains a synthetic example.

| Metric | Labels | Meaning |
| --- | --- | --- |
| `reminders_accounts` | None | Accounts owning accessible reminder lists. |
| `reminders_lists` | `account_id` | Accessible lists in each account. |
| `reminders_list_info` | `account_id`, `list_id`, `name` | List identity and name; value is 1. |
| `reminders_items` | `account_id`, `list_id`, `status` | Reminders partitioned into `incomplete` and `completed`. |
| `reminders_incomplete_items_by_priority` | `account_id`, `list_id`, `priority` | Incomplete reminders: `none` (0), `high` (1–4), `medium` (5), `low` (6–9). |
| `reminders_incomplete_items_by_due_status` | `account_id`, `list_id`, `due_status` | Incomplete reminders: `overdue`, `today`, `future`, `unscheduled`. |
| `reminders_scheduled_items` | `account_id`, `list_id` | Reminders with due components, including unclassifiable dates. |
| `reminders_recurring_items` | `account_id`, `list_id` | Reminders with stored recurrence rules. |
| `reminders_items_with_alarms` | `account_id`, `list_id` | Reminders with alarms. |

The last three counts include completed reminders and count objects, not rules or
alarms. These counts overlap. Totals are obtained by summing the relevant series.

## Counting and labels

Count each accessible EventKit reminder once in its owning list, including
completed records and accessible subtasks. Do not expand future recurrence
instances. Empty lists are included; accounts without accessible lists are not.
Smart views and list groups are not additional owning lists.

Every list emits both completion categories and all priority/due categories,
including zeros, when classification succeeds. Each partition of incomplete
reminders sums to the incomplete total. Unclassifiable due components omit that
list's entire due-status family; other counts remain available. Invalid priorities
fail inventory validation. Zero never substitutes for a failed read.

IDs are opaque and may change after account resets or full synchronization.
Names appear only on `reminders_list_info`, so renames preserve count-series
identity. List names cannot be suppressed. No reminder IDs, titles, notes, or
URLs appear in labels; series cardinality grows with lists, not reminders.

## Deadline classification

One observation instant and the host's local reporting zone apply to an inventory:

1. `unscheduled`: no due components; an alert alone is not a deadline.
2. `overdue`: a timed deadline is before the observation instant, or an all-day
   calendar date is before today.
3. `today`: remaining timed deadlines fall today, or an all-day date equals today.
4. `future`: remaining deadlines fall on a later day.

All-day dates retain their calendar day. Floating timed dates use the host zone;
zoned timed dates are converted to it. Unsupported or non-roundtripping components
are unclassifiable. A timed deadline exactly at the observation instant is `today`.
Thus `today` excludes overdue items and need not match Reminders.app's Today view.
The API's due-status classification uses the same rules, independently of completion.

## Collection and failures

Collection runs at startup, then waits one hour after each attempt. Set
`--metrics-interval-seconds` to change the delay (1–604800 seconds). Collections
never overlap or catch up in bursts. HTTP scrapes only read cached text; GraphQL
and MCP requests neither refresh nor share this cache. Metrics use no AppleScript
and expose no flag counts.

Before collection succeeds, or after a collection fails, `/metrics` returns 503.
A failure clears the previous snapshot; retries use the same delay. During an
in-progress refresh, the previous successful snapshot remains available. Changes,
including removed lists, appear after a successful refresh, so counts may lag by
the interval plus collection time. Totals describe accessible data, not confirmed
cloud synchronization.

Shutdown cancels the collection loop. An already dispatched EventKit operation
can finish before it returns; see [cancellation limits](DATA_ACCESS.md#execution-and-consistency).

## Queries and validation

Total reminders per list:

```promql
sum by (job, instance, account_id, list_id) (reminders_items)
```

Overdue reminders per list:

```promql
reminders_incomplete_items_by_due_status{due_status="overdue"}
```

Incomplete counts with list names:

```promql
reminders_items{status="incomplete"}
* on (job, instance, account_id, list_id) group_left(name)
reminders_list_info
```

Keep instances separate when they observe the same data. Gauge changes cannot
measure completions per day: deletions and moves also change counts.

Validate the example with `promtool check metrics < docs/metrics.prom` and check
that category sums agree. See the [Prometheus exposition specification](https://prometheus.io/docs/instrumenting/exposition_formats/).
