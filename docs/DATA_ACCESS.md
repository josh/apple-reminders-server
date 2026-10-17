# Reminders data access

`RemindersStore.swift` and `RemindersClient.swift` in `Sources/RemindersServer/`
provide data access within the single `RemindersServer` executable target. It handles EventKit authorization, list/reminder projection,
date components, AppleScript flags, and cross-source identifier validation. It
does not import HTTP, GraphQL, MCP, or Prometheus libraries.

## Boundary

`RemindersClient.swift` exposes typed asynchronous reads, mutations, and navigation.
A shared `withReminders` wrapper serializes operations and transfers only Sendable
value records out of the main-thread framework code. `EventKitRecords.swift`
constructs those records directly from EventKit objects. JSON encoding belongs to
the HTTP API layer; there is no internal JSON command protocol.

`readInventory(includeFlags:)` returns lists, reminders, and the accessible default
list ID. Plain inventories use EventKit alone. Flag enrichment uses a fixed
AppleScript read and validates identifiers against the fetched reminders.
[Lazy GraphQL field resolution](APPLESCRIPT.md) controls when flags are needed.

`readProperty` accepts typed descriptors for list emblems, alert dates, and list or
reminder containers. Each descriptor supplies a fixed read-only script expression
and a typed decoder. Before/after identifier checks detect collection changes.
An absent object is distinct from a present object whose property is null.
Client-supplied script source is never executed.

List records include identity, name, color, source, and modification/subscription
capabilities. Reminder records include identity, list membership, text,
completion, priority, timestamps, flags, component dates, location, URL, alarms,
and recurrence rules. Optional values remain optional Swift values until API
encoding. Ordinary dates use ISO 8601 strings; component records retain absent
components, calendar, time zone, and leap-month metadata.

`dueStatus` is `unscheduled`, `overdue`, `today`, `future`, or `unknown` when the
components cannot be classified. Classification uses one observation time per
inventory and is independent of completion. Use `completed: false` as well when
requesting outstanding overdue work. GraphQL exposes uppercase enum values;
MCP exposes lowercase strings. Reads validate reminder/list ownership and reject
duplicate reminder IDs, invalid priorities, or unmatched flags.

`dueDay` is nullable canonical Gregorian `YYYY-MM-DD` in the server reporting
zone, sharing deadline-resolution rules with `dueStatus`. All-day dates retain
their calendar day; floating timed dates use the server zone; zoned timed dates
are converted to it. Invalid/non-roundtripping or unsupported components return
null. Inventory `defaultListId` is restricted to the returned accessible lists.
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

`mutateReminder` applies reminder changes, including typed recurrence and zone
values. Flags and alert dates use fixed AppleScript handlers after the EventKit
save. `mutateList` handles list creation, edits and deletion;
`showRemindersObject` performs UI navigation without saving. All three use the same
serialized in-process execution guard. Partial writes are reported with the saved
identifier, not rolled back. Bounded
synchronization retries cover delayed scripting visibility; list colors must
be opaque. See [WRITES.md](WRITES.md).
