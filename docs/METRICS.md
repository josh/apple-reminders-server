# Reminders metrics

`GET /metrics` serves server health and cached EventKit counts in Prometheus
text format 0.0.4. [metrics.prom](metrics.prom) is a synthetic example of every
metric's name, type, labels, and help text. Health metrics are served on every
scrape, whether or not EventKit is readable.

## Counting and labels

Count each accessible EventKit reminder once in its owning list, including
completed records and accessible subtasks. Do not expand future recurrence
instances. Empty lists are included; accounts without accessible lists are not.
Smart views and list groups are not additional owning lists.

Each reminder contributes to exactly one `reminders_items` series, and every list
emits all 40 combinations, including zeros. Unclassifiable due components use
`unknown`. Invalid priorities fail the read; zero never substitutes for a failed
read.

IDs are opaque and may change after account resets or full synchronization.
Names appear only on `reminders_list_info`, so renames preserve count-series
identity, and list names cannot be suppressed. Labels never carry reminder IDs,
titles, notes, or URLs.

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

Collection runs at startup, then waits `--metrics-interval-seconds` (default one
hour) after each attempt. Scrapes return the most recent collection and never
trigger one; GraphQL and MCP requests do not affect it. Metrics never need
Automation permission and expose no flag counts.

Before collection succeeds, or after a collection fails, `/metrics` omits the
EventKit gauges and reports `reminders_eventkit_up 0`. A failure clears the
previous result, and collection retries after a minute, backing off to the
interval, until it succeeds. While a collection is in progress, the previous
result remains available. Changes, including removed lists, appear after a
successful refresh, so counts may lag by the interval plus collection time.
Totals describe accessible data, not confirmed cloud synchronization.

See the [Prometheus exposition specification](https://prometheus.io/docs/instrumenting/exposition_formats/).
