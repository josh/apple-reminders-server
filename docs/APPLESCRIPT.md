# Reminders automation

The Swift server reads native reminder flags by combining
EventKit with the scripting interface of Reminders.app. Public EventKit supplies
the reminder inventory; the app's declared `flagged` property supplies the flag.
This is independent of priority. See the [dictionary](Reminders.sdef).

## Public behavior

AppleScript flag access is always available. HTTP remains the public interface:

- GraphQL resolves nullable `flagged` only when selected.
- MCP reminder tools always enrich flags.
- `/metrics` uses EventKit only, sends no Apple events, and does not report flags.
- Tool discovery and list summaries do not request flag enrichment.

A scripting or identity-mapping failure produces a GraphQL error on the nullable
`flagged` field while other selected fields remain available. MCP reminder reads
fail as a whole if enrichment fails. Metrics do not use automation. A failed
EventKit scrape never publishes a fabricated zero. Reminder mutations also support
flag writes; see [write mutations](WRITES.md).

## GraphQL selection controls flag reads

GraphQL loads EventKit data first and resolves `Reminder.flagged` lazily.
Requests that neither select nor filter by `flagged` send no flag Apple events.
Count-only queries, empty pages, missing-ID lookups, and skipped fields avoid
flag reads unless a flag filter must be evaluated. Aliases, named and inline
fragments, variables, and operation selection are handled by the GraphQL executor;
there is no substring scan or separate selection parser.

```graphql
# EventKit-only query.
{ reminders { totalCount items { id name } } }

# Loads native flags once for the request, then reuses the result.
{ reminders { items { id name flagged } } }
```

The first executed flag resolver loads the bulk flag data. Its request-local
cache shares both success and failure with subsequent flag resolvers, including
other root aliases, so an error does not trigger repeated scripting attempts.
No flag data is cached across HTTP requests. MCP reminder tools always enrich
flags; they do not use GraphQL field selection.

## Execution and permissions

The statically linked [Swift data-access code](DATA_ACCESS.md) embeds a fixed read-only script and
executes it inside the server process through
Foundation's [NSAppleScript](https://developer.apple.com/documentation/foundation/nsapplescript).
The script runs in the server process and sends Apple events to Reminders.app.
There is no `osascript` child or external data helper. Reminders.app is still an
external participant: in-process scripting does not turn its data access into a
local EventKit call, and the app may need to launch to handle the event.

Automation permission is separate from Reminders/EventKit permission. Each
executable includes an
[NSAppleEventsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).
The first enriched read can trigger a macOS consent prompt for controlling Reminders.
The consent names and attribution depend on the executable and its launch context;
sharing a parent terminal is not proof of independent deployment authorization.
For a hardened distribution, review Apple's
[Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
and signing requirements separately. Permission behavior must be evaluated for the executable's signing and launch context.

Script execution uses the process's main thread. Native results are converted to
ordinary application values before HTTP handlers consume them. Scripts use an
Apple event timeout; this is not a hard deadline covering compilation, app launch,
permission prompts, or every part of request execution. No client-provided text is
interpolated into executable script source.

## Identity and consistency

Reminder scripting IDs must use `x-apple-reminder://<UUID>` or an exact UUID.
The mapper canonicalizes UUID case, rejects duplicate normalized identifiers,
and requires an unambiguous match for every fetched EventKit reminder. Extra
scripting IDs are allowed. List IDs are matched directly. Names and enumeration
positions are never used to infer identity.

Scripts read identifiers before and after bulk properties, rejecting changed
inventories. EventKit and scripting reads are not one atomic snapshot; concurrent
changes can still produce errors. The identifier mapping is validated at runtime
and is not an Apple guarantee of identity across the two interfaces.

Bulk reads avoid one event round trip per reminder. Their result and errors are
shared within an API request, with no cross-request automation cache.

## Metadata reads

The server reads list `emblem`, reminder `remind me date`, and both
container properties with independent lazy per-request bulk reads. An emblem is
the list's icon-name string, separate from its color. Container object specifiers
supply a class code and unique identifier; the server validates both before
joining against EventKit objects. It does not match names or guess parents.
IDs are read before and after each bulk property request to detect inventory
changes. No script source includes client input. See [READ_API.md](READ_API.md#automation-metadata-and-alarms)
for the API, missing-container errors, and remaining limitations.

## Mutation and navigation handlers

The server also embeds fixed, parameterized handlers for native flag writes,
alert-date setting, list-emblem writes, and show-in-Reminders actions. Arguments
use `NSAppleEventDescriptor` strings, booleans and dates; request values never
become script source. All handlers run on the same native main-thread guard.
Reminder setters resolve the target inside its expected list by identifier.

EventKit and automation do not form one transaction. A saved object can remain
when a later automation step fails; `WRITE_APPLIED` identifies it. See
[WRITES.md](WRITES.md) for supported fields, coupled alert/date behavior and
error handling. Transient list-visibility and setter errors
have bounded same-ID retries; list creation itself is never retried.
