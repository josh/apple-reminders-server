# AppleScript

Flags, emblems, alert dates, and containers use the [scripting dictionary](Reminders.sdef)
through [NSAppleScript](https://developer.apple.com/documentation/foundation/nsapplescript)
in the server process on the main actor. This may launch Reminders and requires
Automation permission separately from EventKit access.

Compile fixed scripts once and pass client values as typed Apple-event arguments,
never source text. Compile write handlers before saving to avoid partial writes
caused by syntax errors.

## Reads and identity

Accept bare UUIDs or `x-apple-reminder://<UUID>` for reminders,
`x-apple-reminderkit://REMCDList/<UUID>` for lists, and
`x-apple-reminderkit://REMCDAccount/<UUID>` for accounts. Match canonical UUIDs;
Apple does not guarantee cross-API correspondence. Names/positions are not identity.

Read IDs before and after each bulk property read; require matching counts,
unchanged order, unique IDs, and typed values. Fail inconsistent reads. Scripting
and EventKit are not atomic. Cache each property's result/failure per GraphQL
request; invalidate after attempted mutations.

A property's `missing value` becomes null; a missing object or invalid flag is
an error, never false. Containers require unique-ID references with account/list
parents for lists, list/reminder parents for reminders. Reads use 10-second event
timeouts and no automatic retries.

## Writes

Save through EventKit once, then set requested scripting properties. Match reminder
and containing list IDs before setting. Verify returned identity and values
(alert dates within one second), then reset/refetch. Echo a successfully written flag.

To accommodate delayed scripting visibility, retry only the post-save step for
`-1728` (missing object), `-10006` (cannot set), and `-1712` (event timeout).
Wait 500 ms after a retryable failure if less than 15 seconds have elapsed;
each attempt has a 3-second event timeout. Waits release the actor. Other errors
are final; never replay the native save.

Post-save failure or cancellation returns `WRITE_APPLIED` with the saved ID.
Scripts may partly apply changes. Event timeouts exclude app launch and do not
bound the entire operation; see [server recovery](SERVER.md#deadlines-and-recovery).

## Navigation

`show` requires a UUID and an existing native object. Use the dictionary's command
with a 10-second event timeout, no save, and no retry. Failed/mismatched replies
return `SHOW_FAILED` because the UI may have changed; later MCP response-conversion
failure returns `SHOW_APPLIED`.
