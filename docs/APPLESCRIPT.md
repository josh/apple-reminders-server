# Reminders automation

The server uses Foundation's
[NSAppleScript](https://developer.apple.com/documentation/foundation/nsapplescript)
to read flags, list emblems, alert dates, and container references declared in the
[scripting dictionary](Reminders.sdef). It also sets flags, alert dates, and
emblems, and navigates the Reminders UI.

Scripts execute inside the server and send Apple events to Reminders.app, which
may launch to handle them. See [permissions](SERVER.md#permissions-and-execution)
and [main-thread execution and timeouts](DATA_ACCESS.md#execution-and-consistency).

## Handlers and identity

Read expressions are fixed in typed property descriptors. Write and navigation
handlers receive `NSAppleEventDescriptor` strings, booleans, and dates; client
values never become executable script source. Reminder setters resolve the target
by both reminder ID and expected list ID before sending a set event.

Flags accept `x-apple-reminder://<UUID>` or an exact UUID. Metadata/container IDs
use the declared reminder, list, and account URL forms. UUIDs are canonicalized;
duplicate normalized IDs and unsupported container classes are rejected. A fetched
reminder without a scripting match has an unknown flag; extra scripting IDs are
allowed. Names and enumeration positions never establish identity.

Bulk scripts read identifiers before and after properties and reject changed
inventories. This detects some concurrent edits but does not make the EventKit
and scripting reads atomic. Cross-interface ID matching is checked at runtime,
not guaranteed by Apple. A present null property remains distinct from a missing
object.

## API integration

[GraphQL selection and request caching](READ_API.md#automation-metadata-and-alarms)
control lazy property reads. [MCP](MCP.md) reads and [metrics](METRICS.md) use
EventKit alone; MCP uses automation only for writes and `*_show`. There is no
cross-request automation cache.
