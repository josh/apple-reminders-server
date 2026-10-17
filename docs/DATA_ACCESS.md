# Data-access architecture

The single `RemindersServer` executable contains the HTTP adapters and data-access
code. Project code is linked into the executable; macOS frameworks and Swift
runtime libraries remain dynamic.

| Source | Responsibility |
| --- | --- |
| `RemindersClient.swift` | Typed async reads, mutations, and UI navigation through `withReminders`. |
| `RemindersStore.swift` | Authorization, EventKit inventory, ownership validation, and deadline classification. |
| `EventKitRecords.swift` | Convert framework objects into Sendable records before leaving the main thread. |
| `AppleScriptReads.swift` | Fixed bulk property reads with typed decoders; see [automation](APPLESCRIPT.md). |

JSON encoding happens at the API boundary. GraphQL uses dynamic `Map` values;
MCP uses validated `Value` inputs and schemas. These API boundaries are not fully
checked at compile time.

## Execution and consistency

`withReminders` serializes operations on a worker queue and dispatches framework
access to the process main thread. The main run loop stays available for callbacks
and Apple events. A reentrancy guard rejects nested operations while that run loop
is pumping. Only value records cross back to HTTP handlers.

Each inventory fetch uses one EventKit store and observation time. It rejects
duplicate reminder IDs, invalid priorities, and reminders outside the fetched
lists; the default list must also belong to that inventory. Inventories are
best-effort reads, not atomic snapshots across EventKit and Reminders.app.

Cancellation cannot forcibly stop a dispatched framework call. EventKit callback
waits time out after 30 seconds; Apple-event timeouts apply per event. Permission
dialogs, app launch, and queueing are not covered by a total request deadline.
Serialization remains in place until the operation actually completes, even if
the HTTP client disconnects.

See [server permissions](SERVER.md#permissions-and-execution),
[read caching](READ_API.md#automation-metadata-and-alarms), and
[mutation execution and errors](WRITES.md#execution-and-errors).
