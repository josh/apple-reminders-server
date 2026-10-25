# Reminders automation

Reminders.app exposes flags, list emblems, alert dates, and container references
only through its [scripting dictionary](Reminders.sdef), reached by sending Apple
events, for example with Foundation's
[NSAppleScript](https://developer.apple.com/documentation/foundation/nsapplescript).
Reminders.app may launch to handle them, and sending them requires Automation
permission, which is separate from EventKit access.

## Identity

Reminder identifiers have the form `x-apple-reminder://<UUID>`. Container
references identify lists and accounts as `x-apple-reminderkit://REMCDList/<UUID>`
and `x-apple-reminderkit://REMCDAccount/<UUID>`. Canonicalize UUIDs before
comparing them. Names and enumeration positions never establish identity.

Apple does not guarantee that scripting identifiers correspond to EventKit
identifiers, so check matches at runtime. Scripting and EventKit reads are not
atomic with each other. A property that is present with `missing value` is
distinct from a missing object.
