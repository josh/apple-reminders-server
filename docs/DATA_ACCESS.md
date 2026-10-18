# Data-access architecture

The single `apple-reminders-server` executable contains the HTTP adapters and data-access
code. Project code is linked into the executable; macOS frameworks and Swift
runtime libraries remain dynamic.

| Source | Responsibility |
| --- | --- |
| `RemindersClient.swift` | Typed async reads, mutations, and UI navigation. |
| `RemindersStore.swift` | Authorization, EventKit inventory, ownership validation, and deadline classification. |
| `EventKitRecords.swift` | Convert framework objects into Sendable records. |
| `AppleScriptReads.swift` | Fixed bulk property reads with typed decoders; see [automation](APPLESCRIPT.md). |

JSON encoding happens at the API boundary. GraphQL uses dynamic `Map` values;
MCP uses validated `Value` inputs and schemas. These API boundaries are not fully
checked at compile time.

## Consistency

Each inventory fetch uses one EventKit store and observation time. It rejects
duplicate reminder IDs, invalid priorities, and reminders outside the fetched
lists; the default list must also belong to that inventory. Inventories are
best-effort reads, not atomic snapshots across EventKit and Reminders.app.

See [server permissions](SERVER.md#permissions-and-execution),
[read caching](READ_API.md#automation-metadata-and-alarms), and
[mutation execution and errors](WRITES.md#execution-and-errors).
