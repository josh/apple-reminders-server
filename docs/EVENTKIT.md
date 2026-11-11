# EventKit

Use [EKEventStore](https://developer.apple.com/documentation/eventkit/ekeventstore)
for reminder data and [automation](APPLESCRIPT.md) for scripting-only properties.

## Ownership and access

Native calls run on the main actor in the server process. Each read/write phase
uses a fresh store, kept alive until conversion to value records to preserve
list/account references. Only value records leave the actor. Awaited fetches and
retry waits allow requests to interleave; multi-step writes are not globally serialized.

Require full access before operations and recheck after awaited fetches. Denied
access fails rather than returning empty data. See [startup authorization](SERVER.md#setup).

A reminder list is an [EKCalendar](https://developer.apple.com/documentation/eventkit/ekcalendar),
owned by an [EKSource](https://developer.apple.com/documentation/eventkit/eksource).
Use `calendars(for: .reminder)`; `sources` includes unrelated accounts. ID lookups
must check reminder support; defaults count only if accessible. Check list
editability before writing, while allowing for native save failures.

## Reads

`predicateForReminders(in:)` includes completed and undated reminders in selected lists.
Incomplete predicates optionally bound due dates; completed predicates bound completion dates.
See the [predicate reference](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders).

Scoped searches intersect list/account scopes and select completed/incomplete predicates.
Empty scopes, or completion bounds with `completed: false`, skip fetching after
validating bounds. Widen supplied completion bounds by one second in each direction,
then apply exact inclusive-lower/exclusive-upper bounds to millisecond-serialized
completion dates. This avoids native precision and endpoint differences losing matches.
Due-date filtering uses shared projections, not native due bounds. Unscoped snapshots
fetch all accessible reminders.

Nil calendars means all lists; skip fetching when no accessible lists exist.
`fetchReminders(matching:completion:)` has a 30-second limit. Finish its waiter
on completion, cancellation, or timeout and call `cancelFetchRequest(_:)`;
cancellation may suppress the callback. A nil result fails the read.

Fail snapshots with duplicate IDs, missing owners, out-of-scope lists, or priorities
outside 0–9; never drop bad records silently. Use one observation time per snapshot.
Verify direct item lookups return `EKReminder`.

[EKReminder](https://developer.apple.com/documentation/eventkit/ekreminder) and
[EKCalendarItem](https://developer.apple.com/documentation/eventkit/ekcalendaritem)
define stored fields. Group by owning calendar and use `isCompleted` even without
`completionDate`. Retain raw components, all alarms, and all recurrence rules.

## Dates and recurrence

Simplified dates require Gregorian/unset calendars, era 1/unset, valid year/month/day
in years 1–9999, and valid clock components. An hour marks a timed date; smaller
clock fields require it and default to zero when absent. Floating dates use the
host zone. Reject invalid zones and year/month/day/hour/minute/second round-trip
changes, including DST gaps. Repeated wall times use `Calendar.date(from:)`;
there is no separate occurrence selector.

Zone changes preserve timed instants and date-only calendar days. Clearing a zone
converts to host wall time before making it floating: January 1 at 17:00Z becomes
09:00 in Los Angeles, then floating 09:00 if cleared on that host. See
[Metrics](METRICS.md#deadlines) for reporting-day classification.

Unsupported dates retain raw components and fail simplified projection. Deadline
bounds exclude unresolvable dates; due-date sorting fails rather than inventing an
order.

Use [EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule)
for repetition; do not generate future reminders or repair native DST shifts.
The simplified API supports one rule. Selector arrays must be nonempty and unique;
monthly weekday ordinals are limited to ±5, yearly to ±53, and ordinal weekdays
cannot combine with `weeksOfYear`. Interval/count must fit positive Int32.
An explicit end must choose exactly one of count or until.

Completion uses native coupling: completing stamps now, reopening clears the date,
and setting a completion date marks completed. After setting or clearing completion,
reset/refetch the saved ID to return current state; failure returns `WRITE_APPLIED`.
iCloud checks advanced the original ID to the next incomplete occurrence and created
a completed copy with another ID. Reopening the copy did not rewind the series.
DST shifted starts and relative alarms while due times stayed fixed. These are
provider observations.

## Writes

Assign new reminders a calendar and new lists a source. Validate resulting state
before saving with `commit: true`. Check start ≤ due only when setting start/due or
setting/clearing their zone, so native recurrence dates cannot block unrelated edits.
Enforce relative-alarm requirements on every write. Reject date-only starts and
free-text locations because storage normalizes/discards them. Scripting changes
follow the save; see [write phases](APPLESCRIPT.md#writes).

Moves reassign the existing reminder's calendar and reset/refetch to verify its
destination; both lists must be editable. Do not recreate the reminder. List deletion
checks emptiness unless `allowNonEmpty`; external edits remain unlocked.

Clearing completed reminders requires an explicit editable list. After fetching,
recheck access, completion, membership, and editability. Stage deletes with
`commit: false`, then commit once; empty results return zero. Failure resets the
store and returns `WRITE_FAILED`, without guaranteeing rollback of persisted deletes.

### Alarms

[EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm) supports absolute,
relative, and [location](https://developer.apple.com/documentation/eventkit/ekstructuredlocation)
triggers. Keep combined/invalid triggers raw; fail simplified projection. Validate
sound names against available system sounds. Native objects may retain a sound
with a display action, or retain it when an email address is set.

For sound/email writes, reset/refetch and match every requested trigger/delivery
once; sound permits display or audio action. Missing/changed settings return
`WRITE_APPLIED` with the ID. Stored settings do not prove delivery. iCloud on macOS
27.2 (26B123) dropped sound/email for absolute/relative alarms, retaining display
triggers; the writes returned `WRITE_APPLIED`. Tests used disposable 2099 triggers
and did not test delivery.

## Identity and refresh

`calendarItemIdentifier` may change after full sync. `calendarItemExternalIdentifier`
is server-provided but not unique across copies; `calendarItems(withExternalIdentifier:)`
may return multiple matches. Preserve source/list context; never substitute a same-title
reminder for a missing ID.

[EKEventStoreChanged](https://developer.apple.com/documentation/eventkit/updating-with-notifications)
signals invalidation, not item deltas. Creation/modification timestamps are not a
change feed, and `refreshSourcesIfNecessary()` does not prove cloud sync has finished.
