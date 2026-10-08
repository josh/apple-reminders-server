# EventKit data-access reference

EventKit is Apple's public framework for reading and changing calendars and
reminders. The server uses it for inventory, metrics, and supported writes.
This reference covers relevant public APIs; [DATA_ACCESS.md](DATA_ACCESS.md)
describes the implemented call paths. Method names use Swift notation.

Start with Apple's [EventKit overview](https://developer.apple.com/documentation/eventkit),
[accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store),
and [retrieving events and reminders](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders).

## Objects and terminology

| EventKit type | Meaning for this project | Apple reference |
| --- | --- | --- |
| `EKEventStore` | Access point for authorization, discovery, queries, and writes. | [Event store](https://developer.apple.com/documentation/eventkit/ekeventstore) |
| `EKSource` | Source/account that owns calendars. | [Source](https://developer.apple.com/documentation/eventkit/eksource) |
| `EKCalendar` with reminder support | A reminder list, despite the calendar terminology. | [Calendar](https://developer.apple.com/documentation/eventkit/ekcalendar) |
| `EKReminder` | Reminder-specific state, dates, and priority. | [Reminder](https://developer.apple.com/documentation/eventkit/ekreminder) |
| `EKCalendarItem` | Inherited fields such as title, notes, identifiers, alarms, and recurrence. | [Calendar item](https://developer.apple.com/documentation/eventkit/ekcalendaritem) |

Not every source has reminder lists. Do not use the count of all `sources` as
the reminder-account count without deciding what qualifies as an accessible
reminder account. Grouping discovered reminder calendars by source is a useful
starting point, but may omit accounts without a currently visible reminder list.
Source ordering is not a display-order contract.

## Authorization

| API or setting | Why it is useful |
| --- | --- |
| `EKEventStore.authorizationStatus(for: .reminder)` | Check current access before treating an empty read as an empty collection. |
| `requestFullAccessToReminders(completion:)` | Request reminder access; available on macOS 14 and later. |
| `NSRemindersFullAccessUsageDescription` | Describe why an application requests reminder access. |

Apple references: [requesting full reminder access](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders%28completion%3A%29),
[authorization status](https://developer.apple.com/documentation/eventkit/ekeventstore/authorizationstatus%28for%3A%29),
and [usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremindersfullaccessusagedescription).

Read-only collection still uses the full-access Reminders authorization model;
the write-only event permission is for calendar events. Sandboxed macOS packaging
also needs the applicable entitlement described in Apple's
[access guide](https://developer.apple.com/documentation/eventkit/accessing-the-event-store).
Exact authorization behavior should be tested in the intended host application
or service context. An Automation grant for controlling Reminders.app is separate.

## Discover accounts and lists

| Call or property | Useful behavior |
| --- | --- |
| `calendars(for: .reminder)` | Enumerate accessible reminder lists. Start here for list inventory and per-list collection. |
| `sources` | Enumerate sources, including ones unrelated to reminders. |
| `calendar.source` | Associate a list with its source/account. |
| `sourceIdentifier`, `source.title`, `sourceType` | Identify and describe the account/source. |
| `calendarIdentifier`, `calendar.title` | Identify and name each list without relying on unique names. |
| `calendar(withIdentifier:)` | Resolve a previously discovered list ID. |
| `defaultCalendarForNewReminders()` | Obtain the default destination list; may return nil. |
| `allowsContentModifications` | Check whether reminders in a list can be added, edited, or deleted. |
| `isImmutable`, `isSubscribed`, `cgColor` | Read list editability, subscription status, and color. |

See [EKEventStore](https://developer.apple.com/documentation/eventkit/ekeventstore),
[EKCalendar](https://developer.apple.com/documentation/eventkit/ekcalendar), and
[EKSource](https://developer.apple.com/documentation/eventkit/eksource).

The default list's source is a useful account association, but should not silently
be presented as an independently verified default-account preference.
`!isImmutable` and `allowsContentModifications` concern different capabilities.
Neither guarantees that every requested operation will succeed.

## Fetch reminders

| Call | When to use it |
| --- | --- |
| `predicateForReminders(in:)` | Build a query for all reminders in selected lists. Useful for complete snapshot counts, including completed and undated items. |
| `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)` | Query incomplete reminders, optionally constrained by due date. |
| `predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)` | Query completed reminders, optionally constrained by **completion date**. |
| `fetchReminders(matching:completion:)` | Execute a reminder predicate asynchronously. Returns a cancellation handle. |
| `cancelFetchRequest(_:)` | Cancel an outstanding fetch using its handle. |
| `calendarItem(withIdentifier:)` | Look up an item directly; verify the result is an `EKReminder`. |

Apple's [retrieval guide](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders)
explains predicate and identifier-based access. Direct references:
[all-reminders predicate](https://developer.apple.com/documentation/eventkit/ekeventstore/predicateforreminders%28in%3A%29),
[incomplete predicate](https://developer.apple.com/documentation/eventkit/ekeventstore/predicateforincompletereminders%28withduedatestarting%3Aending%3Acalendars%3A%29),
[completed predicate](https://developer.apple.com/documentation/eventkit/ekeventstore/predicateforcompletedreminders%28withcompletiondatestarting%3Aending%3Acalendars%3A%29),
[fetch](https://developer.apple.com/documentation/eventkit/ekeventstore/fetchreminders%28matching%3Acompletion%3A%29),
and [cancellation](https://developer.apple.com/documentation/eventkit/ekeventstore/cancelfetchrequest%28_%3A%29).

Read semantics:

- Pass explicit calendars when collecting one list. Passing nil means all
  available calendars, not an empty scope.
- For a full list snapshot, fetch once and compute completion, priority, and due
  partitions from the same result. Separate category queries can observe changes
  between reads and yield inconsistent totals.
- Use the store's supported predicate constructors. Arbitrary text searches,
  priority filters, sorting, and offset pagination can be applied after fetching;
  these fetch methods do not provide the documented API's pagination contract.
- Do not use the completed-date predicate to implement a due-date filter on
  completed reminders. Those are different dates.
- Preserve the distinction between a nil fetch result and an empty array. The
  callback has no error argument, so nil alone is not a detailed failure reason.
  Check authorization and treat an indeterminate read as unavailable, not zero.
- The installed header says cancellation prevents the completion callback.
  An async wrapper must settle cancellation itself and handle races;
  it cannot assume the callback will finish its pending operation.

## Fields worth reading

| Field or measurement | EventKit properties | Notes |
| --- | --- | --- |
| Reminder identity and list | `calendarItemIdentifier`, `calendar` | Use the actual owning calendar when grouping results. |
| Name and body | `title`, `notes` | Inherited from `EKCalendarItem`. |
| Completed/incomplete counts | `isCompleted` | Do not infer completion solely from the presence of a completion date. |
| Completion timestamp | `completionDate` | Can be absent even for a completed reminder from another client. |
| Priority partitions | `priority` | 0 none, 1–4 high, 5 medium, 6–9 low. |
| Start and due dates | `startDateComponents`, `dueDateComponents` | Preserve date-only versus timed values and floating time-zone semantics. |
| Created/modified metadata | `creationDate`, `lastModifiedDate` | Useful for display and sorting, not a substitute for a change feed. |
| Location and URL | `location`, `url` | Location text is separate from a geofence; a URL does not guarantee a rich-link attachment in the app. |
| Alerts | `alarms` | Examine each `EKAlarm`, not just one alert timestamp. |
| Repeating schedule | `recurrenceRules` | Apple documents support for a single recurrence rule. |

See [EKReminder](https://developer.apple.com/documentation/eventkit/ekreminder),
[EKCalendarItem](https://developer.apple.com/documentation/eventkit/ekcalendaritem),
[EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm),
[EKStructuredLocation](https://developer.apple.com/documentation/eventkit/ekstructuredlocation),
[EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule),
and [recurrence-rule support](https://developer.apple.com/documentation/eventkit/ekcalendaritem/recurrencerules).

The reminder date properties use `DateComponents`. Apple's installed header
describes nil time zones as floating and dates without time components as all-day;
setting these components requires a Gregorian calendar. Do not normalize every
deadline into UTC midnight. Use the explicit reporting rules in [METRICS.md](METRICS.md)
when assigning due-status categories, and test date-boundary behavior rather than
assuming predicate boundaries match those reporting rules exactly.

The installed recurrence-rule initializer documents `daysOfTheMonth` for monthly
rules only; other frequencies ignore it. Reject unsupported input combinations
instead of accepting a schedule that would silently lose constraints. Recurrence
weekday ordinals must also fit the frequency; verify boundary cases in fixtures.

## Identifiers and refresh

Apple warns that `calendarItemIdentifier` can be lost during a full sync.
`calendarItemExternalIdentifier` is a server-provided alternative, but is not
guaranteed unique across copies. `calendarItems(withExternalIdentifier:)` can
therefore return multiple matches. Preserve source/list context when reconciling;
never silently mutate a same-title reminder as a substitute for a missing ID.
See [local identifier](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier)
and [external identifier](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier).

The server treats identifiers as opaque and validates the EventKit/automation
join at runtime; see [APPLESCRIPT.md](APPLESCRIPT.md). Source IDs are not
guaranteed to survive account resets or full synchronization.

`Notification.Name.EKEventStoreChanged` is an invalidation signal rather than
a per-item delta log. The server obtains fresh request inventories and uses a
timed metrics collector; it does not subscribe to this notification.
Apple's [notification guide](https://developer.apple.com/documentation/eventkit/updating-with-notifications)
explains why previously fetched objects can become stale.

`refreshSourcesIfNecessary()` asks the store to refresh when needed; it is not
a guarantee that a cloud sync has completed or that retained objects are current.
See [refresh sources](https://developer.apple.com/documentation/eventkit/ekeventstore/refreshsourcesifnecessary%28%29).

## Fields requiring automation

Public reminder properties do not include native flags, tags, section membership,
attachments, assignments, urgent state, or a parent/subtask relationship. These
are gaps in the public model, not values to report as false or empty.

The [scripting dictionary](Reminders.sdef) separately declares native
flags, list emblems, alert dates, and container references. The server
reads these through in-process automation, checks identifiers, and resolves
containers against the accessible EventKit inventory. See [READ_API.md](READ_API.md)
for lazy field reads and unresolvable-container behavior. An EventKit-only
metrics collector cannot faithfully publish the flagged family from priority,
so metrics exclude flags. Counts describe accessible EventKit records, not
every view in Reminders.app.

## Related write calls

Although retrieval is the focus here, these calls are useful references for the
documented mutations:

| Call | Purpose |
| --- | --- |
| `EKReminder(eventStore:)` | Construct a reminder, then assign its calendar and properties. |
| `save(_:commit:)` / `remove(_:commit:)` for reminders | Persist changes or delete a reminder. |
| `EKCalendar(for: .reminder, eventStore:)` | Construct a reminder list; select an appropriate source. |
| `saveCalendar(_:commit:)` / `removeCalendar(_:commit:)` | Persist or delete a list, subject to source capabilities. |
| `commit()` | Save pending changes when using deferred commits. |

Apple references: [creating events and reminders](https://developer.apple.com/documentation/eventkit/creating-events-and-reminders)
and [EKEventStore](https://developer.apple.com/documentation/eventkit/ekeventstore).
Deferred commits should not be advertised as a general transaction/rollback
guarantee for the multi-operation API. Completing a reminder and setting
its completion date are coupled operations; test recurrence and completion
behavior before claiming a faithful round trip.
