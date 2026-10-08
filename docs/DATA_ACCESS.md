# Reminders data access

`RemindersStore.swift` and `RemindersClient.swift` in `Sources/RemindersServer/`
provide data access within the single `RemindersServer` executable target. It handles EventKit authorization, list/reminder projection,
date components, AppleScript flags, and cross-source identifier validation. It
does not import HTTP, GraphQL, MCP, or Prometheus libraries.

## Boundary

The host calls `remindersRead(_:listID:)`, which returns Swift `Data` or throws a
Swift error. No C ABI, manually freed buffers, or project dylib is required. The
JSON projection remains a runtime boundary; the HTTP layer decodes and validates
it into typed records. Data-access responses are decoded and validated at this boundary.

String commands support reads, status, and explicit startup authorization.
A separate typed `remindersMutate` entrypoint supports EventKit reminder
create/update/delete; see [WRITES.md](WRITES.md). There is no client-supplied script source. Plain reads never invoke flag
scripting; enriched reads always do.
[Lazy GraphQL field resolution](APPLESCRIPT.md) still controls when flags are needed.

### Commands and JSON projection

| Command | Successful response | Flag scripting |
| --- | --- | --- |
| `status` | `{authorization: string}` | Never |
| `authorize` | `{authorization: string}` after explicit permission request | Never |
| `lists` | `{lists: [...], defaultListId: string or null}` | Never |
| `defaults` | `{defaultListId: string or null}` | Never |
| `reminders-base` | `{reminders: [...]}` | Never |
| `reminders` | `{reminders: [...]}` | Always |
| `snapshot_plain` | `{lists: [...], reminders: [...], defaultListId: string or null}` | Never |
| `script-emblems` | Object keyed by normalized list ID; icon string or null | Never |
| `script-alerts` | Object keyed by normalized reminder ID; timestamp or null | Never |
| `script-list-containers` | Object keyed by list ID; `{kind, id}` references | Never |
| `script-reminder-containers` | Object keyed by reminder ID; `{kind, id}` references | Never |
| `snapshot` | `{lists: [...], reminders: [...], defaultListId: string or null}` | Always |

The `script-*` commands always use automation, independently of flag reads. They
are fixed read-only scripts, with before/after identifier validation.

List records contain `color` (sRGB `#RRGGBBAA` or null), `id`, `title`, `source` (`id`, `title`, integer `type`),
`allowsContentModifications`, `immutable`, and `subscribed`. Reminder records
contain `id`, `externalId`, `listId`, `title`, `notes`, `completed`, nullable
`flagged`, `priority`, `completionDate`, `creationDate`, `lastModifiedDate`,
`startDateComponents`, `dueDateComponents`, `location`, `url`, `alarms`,
`recurrenceRules`, `dueDay`, and `dueStatus`. Optional values are explicit JSON null. Ordinary dates are ISO 8601
strings; component objects retain absent components, calendar, timeZone, floating,
allDay, and isLeapMonth metadata. The host maps these wire names to its public API.

`dueStatus` is one of `unscheduled`, `overdue`, `today`, `future`, or null when the
components cannot be classified. It uses one observation time for a snapshot;
the API and metrics handlers consume it for metrics and expose it for API filtering. GraphQL uses
uppercase enum values; MCP uses lowercase strings, with `unknown` for missing value.
Classification is independent of completion: use `completed: false` as well when
requesting outstanding overdue work. EventKit reads validate
reminder/list ownership and reject duplicate reminder IDs or unmatched flags.

`dueDay` is nullable canonical Gregorian `YYYY-MM-DD` in the server reporting
zone, sharing deadline-resolution rules with `dueStatus`. All-day dates retain
their calendar day; floating timed dates use the server zone; zoned timed dates
are converted to it. Invalid/non-roundtripping or unsupported components return
null. Snapshot/list `defaultListId` is restricted to the returned accessible lists.
See [READ_API.md](READ_API.md) for date search and per-request inventory semantics.

## Alarm and recurrence projection

`alarms` and `recurrenceRules` are always arrays; absent EventKit collections become
empty arrays. These are stored definitions, not a schedule of generated instances.

Each alarm has nullable `absoluteDate`, numeric `relativeOffset` in seconds,
`proximity` (`none`, `enter`, `leave`, or `unknown`), and nullable
`structuredLocation`. A location contains nullable `title`, `latitude`, and
`longitude`, plus `radius` in meters. Zero offset does not by itself distinguish
an absolute alarm from a relative alarm; inspect `absoluteDate` and proximity.
See Apple's [EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm)
and [structuredLocation](https://developer.apple.com/documentation/eventkit/ekalarm/structuredlocation)
references. Alarm actions such as sound/email are not part of this projection.

Each recurrence rule preserves `calendarIdentifier`, `frequency`, `interval`,
`firstDayOfTheWeek`, `daysOfTheWeek` (objects with `dayOfTheWeek` and `weekNumber`),
`daysOfTheMonth`, `daysOfTheYear`, `weeksOfTheYear`, `monthsOfTheYear`,
`setPositions`, and nullable `end` (`endDate`, `occurrenceCount`). Optional EventKit
constraint arrays become empty arrays. Signed ordinal values are preserved.
Weekday numbering is Sunday = 1 through Saturday = 7; zero `firstDayOfTheWeek`
means unset. A missing end means no explicit end; a date-based end has zero
occurrence count. See Apple's
[EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule)
reference. The API does not calculate future occurrences or infer recurrence
rules that EventKit did not return.

## Execution and authorization

The data-access code runs EventKit and AppleScript operations on the process main thread, dispatching there
when entered from another thread. The server serializes data-access calls. A main-thread
reentrancy guard rejects overlapping data-access execution rather than allowing nested
script reads while a Cocoa run loop is pumping.

The Swift host keeps its main run loop available and dispatches blocking reads
from its serialized worker queue. These are threads inside the server, not
subprocesses. EventKit and Automation permissions remain separate and belong to
the executable's launch identity. There is no helper, direct SQLite access, or
private ReminderKit API.

Cancellation still cannot forcibly stop a running data-access call. EventKit fetches
and Apple events have their existing timeouts; permission dialogs, queueing, and
app launch do not form a hard wall-clock deadline. The host must keep serialization
in place until the data-access call actually completes, even if an HTTP client leaves.

## Build and deployment

The package has one executable target. `swift build` compiles the data-access and
HTTP code together, using internal declarations rather than public module exports.
The Nix package uses the same layout and has no separate data-access derivation. System frameworks and Swift runtime libraries remain dynamically
supplied by macOS. Runtime permissions and signing still apply; no signed app bundle
is produced by these development builds.

## Additional write entrypoints

`remindersMutate` applies reminder changes, including typed recurrence and zone
values. Flags and alert dates use fixed AppleScript handlers after the EventKit
save. `remindersMutateList` handles list creation, edits and deletion;
`remindersShow` performs UI navigation without saving. All three use the same
serialized in-process serialization guard. Partial writes are reported with the saved
identifier, not rolled back. Bounded
synchronization retries cover delayed scripting visibility; list colors must
be opaque. See [WRITES.md](WRITES.md).
