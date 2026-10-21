# Reminders metrics

`GET /metrics` serves server health and cached EventKit counts in Prometheus
text format 0.0.4. [metrics.prom](metrics.prom) contains a synthetic example of
the EventKit gauges.

## Server health

These are served on every scrape, whether or not EventKit is readable.

| Metric | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `process_start_time_seconds` | gauge | None | Process start time; a change is a restart, including a watchdog exit. |
| `reminders_http_requests_total` | counter | `route`, `code` | Responses by route (`/graphql`, `/mcp`, `/metrics`, `other`) and status code. |
| `reminders_main_actor_heartbeat_age_seconds` | gauge | None | Time since the main actor ran the watchdog's heartbeat; the process exits past 120 seconds. |
| `reminders_authorization_pending` | gauge | None | 1 while the `--request-access` startup request is unfinished; `/graphql` and `/mcp` answer 503 meanwhile. |
| `reminders_eventkit_up` | gauge | None | 1 when the last background EventKit read succeeded and the gauges below follow. |

## EventKit gauges


| Metric | Labels | Meaning |
| --- | --- | --- |
| `reminders_accounts` | None | Accounts owning accessible reminder lists. |
| `reminders_lists` | `account_id` | Accessible lists in each account. |
| `reminders_list_info` | `account_id`, `list_id`, `name` | List identity and name; value is 1. |
| `reminders_items` | `account_id`, `list_id`, `status`, `priority`, `due_status` | Reminder counts partitioned by completion, priority, and deadline. |
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

Each reminder contributes to exactly one `reminders_items` series:

- `status`: `incomplete` or `completed`.
- `priority`: `none` (0), `high` (1–4), `medium` (5), or `low` (6–9).
- `due_status`: `overdue`, `today`, `future`, `unscheduled`, or `unknown`.

Every list emits all 40 combinations, including zeros. Sum across unwanted labels
to obtain totals or breakdowns. Unclassifiable due components use `unknown`,
preserving counts in every partition. Invalid priorities fail the read;
zero never substitutes for a failed read. These gauges have no `_count` or `_total`
suffix; see [Prometheus naming conventions](https://prometheus.io/docs/practices/naming/).

IDs are opaque and may change after account resets or full synchronization.
Names appear only on `reminders_list_info`, so renames preserve count-series
identity. List names cannot be suppressed. No reminder IDs, titles, notes, or
URLs appear in labels; series cardinality grows with lists, not reminders.

## Deadline classification

One observation instant and the host's local reporting zone apply to each read:

1. `unscheduled`: no due components; an alert alone is not a deadline.
2. `overdue`: a timed deadline is before the observation instant, or an all-day
   calendar date is before today.
3. `today`: remaining timed deadlines fall today, or an all-day date equals today.
4. `future`: remaining deadlines fall on a later day.

All-day dates retain their calendar day. Floating timed dates use the host zone;
zoned timed dates are converted to it. Unsupported or non-roundtripping components
use `unknown`. A timed deadline exactly at the observation instant is `today`.
Thus `today` excludes overdue items and need not match Reminders.app's Today view.
The API's due-status classification uses the same rules, independently of completion.

## Collection and failures

Collection runs at startup, then waits one hour after each attempt. Set
`--metrics-interval-seconds` to change the delay (1–604800 seconds). Collections
never overlap or catch up in bursts. HTTP scrapes only read cached text; GraphQL
and MCP requests neither refresh nor share this cache. Metrics use no AppleScript
and expose no flag counts.

Before collection succeeds, or after a collection fails, `/metrics` omits the
EventKit gauges and reports `reminders_eventkit_up 0`. A failure clears the
previous result; the next attempt follows after one
minute, then after doubling delays capped at the interval, until collection
succeeds. During an
in-progress refresh, the previous successful result remains available. Changes,
including removed lists, appear after a successful refresh, so counts may lag by
the interval plus collection time. Totals describe accessible data, not confirmed
cloud synchronization.

## Queries and validation

Total reminders per list:

```promql
sum by (job, instance, account_id, list_id) (reminders_items)
```

Incomplete overdue reminders per list:

```promql
sum by (job, instance, account_id, list_id) (
  reminders_items{status="incomplete",due_status="overdue"}
)
```

Incomplete counts with list names:

```promql
sum by (job, instance, account_id, list_id) (reminders_items{status="incomplete"})
* on (job, instance, account_id, list_id) group_left(name)
reminders_list_info
```

Keep instances separate when they observe the same data. Gauge changes cannot
measure completions per day: deletions and moves also change counts.

Validate the example with `promtool check metrics < docs/metrics.prom` and check
that category sums agree. See the [Prometheus exposition specification](https://prometheus.io/docs/instrumenting/exposition_formats/).
