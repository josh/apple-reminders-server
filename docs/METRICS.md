# Reminders data metrics

These metrics describe the current contents of Reminders: how many accounts and
lists are accessible, how many reminders each list contains, and how those
reminders are distributed. They do not measure API traffic or server operations.

[metrics.prom](metrics.prom) is a synthetic example in Prometheus text exposition
format 0.0.4, using `HELP` descriptions, `TYPE` declarations, labels, and values.
This document supplies the counting rules and label definitions that a sample
cannot express. `GET /metrics` serves cached snapshots collected through EventKit.

## Metrics

All metrics are **gauges**. They describe a snapshot and may increase or decrease
as reminders are created, completed, reopened, moved, or deleted.

| Metric | Labels | Meaning |
| --- | --- | --- |
| `reminders_accounts` | None | Number of distinct accounts owning accessible reminder lists. |
| `reminders_lists` | `account_id` | Number of accessible lists in an account. |
| `reminders_list_info` | `account_id`, `list_id`, `name` | List identity and display name; value is always 1. |
| `reminders_items` | `account_id`, `list_id`, `status` | Number of reminders, partitioned into incomplete and completed. |
| `reminders_incomplete_items_by_priority` | `account_id`, `list_id`, `priority` | Incomplete reminders partitioned by priority. |
| `reminders_incomplete_items_by_due_status` | `account_id`, `list_id`, `due_status` | Incomplete reminders partitioned by deadline status. |
| `reminders_scheduled_items` | `account_id`, `list_id` | Reminders with due components, including completed reminders. |
| `reminders_recurring_items` | `account_id`, `list_id` | Reminders with stored recurrence rules, including completed reminders. |
| `reminders_items_with_alarms` | `account_id`, `list_id` | Reminders with alarms, including completed reminders. |

Total counts are derived by summing these series rather than exposed as redundant
metrics. In the example, one account has two lists and 40 reminders: 13 incomplete
and 27 completed. Personal has 20 reminders, and Work has 20.

## Identity and labels

- `account_id` and `list_id` are opaque identifiers within the data source.
  Keep them stable while the source identity persists; account resets or full
  synchronization can replace identifiers and therefore create new series.
  Two lists with the same name remain distinct.
- `name` is the current list display name. It appears only on `reminders_list_info`
  so renaming a list does not change the identity of its count series. Retire the
  old info series when the name changes.
- `status` is `incomplete` or `completed`.
- `priority` is `none` (0), `high` (1–4), `medium` (5), or `low` (6–9).
- `due_status` is `overdue`, `today`, `future`, or `unscheduled`, as defined below.

The number of series scales with lists, not individual reminders. Reminder IDs,
titles, notes, URLs, and attachment names are not labels. List names are included in the info metric; there is no server option to omit them. Collection labels such as `job` and
`instance` are outside this contract.

## Counting rules

Count each distinct reminder once in its owning list. If subtasks are available,
count each subtask as a separate reminder and assign it to the ancestor list;
do not count it again when encountered through another traversal. Count the
parent reminder separately. A list's total therefore includes accessible subtasks.
Do not infer inaccessible subtasks or fabricate an owning list.

Count accessible owning lists, including empty ones, and their distinct accounts.
Accounts without accessible lists are not enumerated. Do not count smart views,
saved searches, or list groups as additional owning lists. Include completed
reminders still present in the accessible data. Exclude deleted reminders and
items in a trash/recently-deleted collection. Do not project future occurrences
of recurring reminders: count the actual reminder records currently present.

For each successfully read list, emit both completion categories, all four priority categories, and all four due categories, including
zeros. An empty list consequently has zero for all its count series and 1 for
its info series.

Each priority and due partition sums to that list's incomplete count. An out-of-range priority is a failed classification, not `none`.

## Deadline classification

Use one observation instant and one reporting time zone for the entire snapshot.
The reporting zone is the host's local zone; there is no separate startup option. It is not a per-reminder label. Changes to the zone can move items
between categories and should be treated as changes in reporting configuration.

Apply these categories in order to incomplete reminders:

1. **Unscheduled:** there is no deadline. An alert alone does not create a deadline.
2. **Overdue:** a timed deadline is strictly before the observation instant, or an
   all-day deadline's calendar date is before today's date in the reporting zone.
3. **Today:** the remaining timed deadline falls on today's date in the reporting
   zone, or the all-day deadline equals today's date.
4. **Future:** the remaining deadline falls on a later date.

An all-day reminder stays in `today` through that calendar day; it becomes overdue
on the next day. A timed reminder due earlier today is `overdue`, not `today`.
A timed reminder due exactly at the observation instant is still `today`.
Preserve an all-day deadline as a calendar date rather than shifting it through
UTC. If the source exposes both date and timestamp representations of one deadline,
use its actual timed/all-day mode; do not count the reminder in two categories.
Unknown or ambiguous deadline mode is a classification failure.

The `today` category means **due later today or all day today**, excluding overdue
items. It is not a promise to reproduce a particular application's Today view.

## Snapshot and missing-data behavior

Compute a list's metrics from one logical read of that list and use the same
observation time for all deadline classifications. Publish completed snapshots,
not partially accumulated counts. A source need not support atomic reads across
all lists, but a list's internal partitions must agree.

Zero means a successful read found no matching items. It must not mean access
was denied, a read failed, or a value could not be classified. If a family cannot
be computed completely for a list, omit that family's series for the list rather
than publishing an undercount or relabeling unknown values. Other independently
known families may remain available. Do not continue presenting an old value as
if it were freshly observed.

An inventory or authorization failure makes the next scrape return HTTP 503.
A reminder whose owning list is absent fails collection. Unclassifiable due
components omit the affected list's due-status series. Totals describe accessible
data, not necessarily every item in iCloud. Removed lists stop emitting series
when the next successful background refresh replaces the snapshot.

## Example queries

Number of lists per observed service instance:

```promql
sum by (job, instance) (reminders_lists)
```

Total reminders per list, including completed:

```promql
sum by (job, instance, account_id, list_id) (reminders_items)
```

Incomplete reminders per instance:

```promql
sum by (job, instance) (reminders_items{status="incomplete"})
```

Overdue reminders per list:

```promql
reminders_incomplete_items_by_due_status{due_status="overdue"}
```

Attach list names to the incomplete counts:

```promql
reminders_items{status="incomplete"}
* on (job, instance, account_id, list_id) group_left(name)
reminders_list_info
```

Keep source instances separate when they observe the same data; summing across
replicas would double-count reminders. Gauge changes do not measure productivity:
for example, a drop in incomplete reminders can mean completion, deletion, or a
move. The endpoint does not report completions per day.

## Format and validation

The `.prom` filename is a convention. The file is an illustrative sample,
not an exporter, live observation, or file to install into a collector. No sample
timestamps are supplied. The collector timestamps each observation.

References: [Prometheus exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/)
and [metric naming](https://prometheus.io/docs/practices/naming/).

When available, lint the fixture with:

```sh
promtool check metrics < docs/metrics.prom
```

Also verify that completion counts sum to expected list totals, priority and due
partitions each equal the incomplete count.


## List-summary gauges

`reminders_scheduled_items`, `reminders_recurring_items`, and
`reminders_items_with_alarms` are gauges labelled by `account_id` and `list_id`.
They count reminders with due components, nonempty recurrence rules, or nonempty
alarm arrays respectively. Completed reminders are included. Scheduled includes
unclassifiable due components; recurring and alarm counts count reminders rather
than individual rules or alarms. Emit zero for empty lists. These overlapping
counts use the same summary calculation as the read-only GraphQL/MCP APIs.
Each background collection uses one EventKit inventory; HTTP scrapes share the cached result. See [READ_API.md](READ_API.md).

## Collection frequency and data sources

The server collects once at startup, then waits one hour after each collection
before refreshing. Set `--metrics-interval-seconds 3600` to change this delay
(allowed range: 1–604800 seconds). Collections never overlap or catch up in bursts.
Every `GET /metrics` serves the cached text without reading Reminders. Prometheus
scrape frequency and the number of clients do not affect collection frequency.
GraphQL and MCP continue to read independently and do not refresh this cache.

Before the first successful collection, or after a collection fails, the endpoint
returns HTTP 503. Failure clears the previous snapshot instead of serving stale
counts indefinitely, and retries follow the same configured delay. While a refresh
is in progress, the previous successful snapshot remains available. Data can lag
behind edits by the configured delay plus collection time. Shutdown cancels the
background loop.

Metrics never request AppleScript enrichment and do not report flags. Scrapes require
EventKit access but do not launch Reminders or request Automation permission.
GraphQL and MCP may still use automation for their requested data.

## Cancellation

Shutdown cancels the collection loop. Cancellation does not forcibly abort an
EventKit callback already dispatched by the data-access bridge; it can finish
before the collector returns. Callback waits have a 30-second timeout, which is
not a guarantee that all OS framework calls are cancellable or bounded.
