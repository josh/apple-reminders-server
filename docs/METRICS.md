# Metrics

`GET /metrics` serves health and cached reminder counts in Prometheus text format
0.0.4. [metrics.prom](metrics.prom) is a synthetic example of every metric, type,
label, and help text; see the [format specification](https://prometheus.io/docs/instrumenting/exposition_formats/).

## Counts

Count each accessible reminder once in its owning list, including completed items
and subtasks. No future recurrence expansion, smart views, or list groups.
Accounts without accessible lists are excluded. Each reminder enters one
`reminders_items` bucket; every list emits all 40 combinations, including zeros.
Invalid priorities fail collection; failed reads never become zeros. No flag counts.

Only `reminders_list_info` includes names; renames preserve count-series identity.
List names cannot be suppressed. Labels exclude reminder IDs, titles, notes, and
URLs. IDs are opaque and may change after account resets or full sync.

## Deadlines

One observation instant and the host's local zone apply per read. These rules also
apply to API due status, independently of completion:

| Status        | Meaning                                                        |
| ------------- | -------------------------------------------------------------- |
| `unscheduled` | No due components; an alert alone is not a deadline.           |
| `overdue`     | Timed deadline before now, or all-day date before today.       |
| `today`       | Due today and not overdue; includes a deadline exactly at now. |
| `future`      | Due after today.                                               |
| `unknown`     | Unsupported or non-roundtripping date components.              |

Resolve components in their stored zone, or the host zone when floating; date-only
values resolve at midnight. Classify the resulting instant by the host's calendar
day. `today` excludes overdue items and can differ from Reminders.app's Today view.

Known limitation: November 8 at midnight in Tokyo reports November 7 in Los Angeles.
Current `dueDay` follows that reporting day even for date-only values, despite the
schema's description; `allDayDueDate` retains November 8.

## Refresh

Collect at startup, then wait `REMINDERS_METRICS_INTERVAL_SECONDS` (default 3600)
after each collection. Scrapes and API requests do not trigger collection.
Counts remain available during refresh and may lag by the interval plus collection
time; changes and removed lists appear on success. Counts do not prove cloud sync.

Before the first success or after failure, omit reminder gauges and report
`reminders_eventkit_up 0`; health metrics remain. Failures clear previous counts
and retry after min(60 seconds, interval), doubling up to the interval.
Collection never needs Automation permission.
Each collection is independent of API request snapshots. The health series cover
the current process; restarts reset counters, and this collector keeps no disk cache.
