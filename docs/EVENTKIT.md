# EventKit data-access reference

EventKit is Apple's public framework for reading and changing calendars and
reminders. This reference covers the public APIs relevant to reminders. Method
names use Swift notation.

Start with Apple's [EventKit overview](https://developer.apple.com/documentation/eventkit),
[accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store),
and [retrieving events and reminders](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders).

## Objects and terminology

| EventKit type | Meaning | Apple reference |
| --- | --- | --- |
| `EKEventStore` | Access point for authorization, discovery, queries, and writes. | [Event store](https://developer.apple.com/documentation/eventkit/ekeventstore) |
| `EKSource` | Source/account that owns calendars. | [Source](https://developer.apple.com/documentation/eventkit/eksource) |
| `EKCalendar` with reminder support | A reminder list, despite the calendar terminology. | [Calendar](https://developer.apple.com/documentation/eventkit/ekcalendar) |
| `EKReminder` | Reminder-specific state, dates, and priority. | [Reminder](https://developer.apple.com/documentation/eventkit/ekreminder) |
| `EKCalendarItem` | Inherited fields such as title, notes, identifiers, alarms, and recurrence. | [Calendar item](https://developer.apple.com/documentation/eventkit/ekcalendaritem) |

## Authorization

| API or setting | Why it is useful |
| --- | --- |
| `EKEventStore.authorizationStatus(for: .reminder)` | Check current access before treating an empty read as an empty collection. |
| `requestFullAccessToReminders(completion:)` | Request reminder access; available on macOS 14 and later. |
| `NSRemindersFullAccessUsageDescription` | Describe why an application requests reminder access. |

Apple references: [requesting full reminder access](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders%28completion%3A%29),
[authorization status](https://developer.apple.com/documentation/eventkit/ekeventstore/authorizationstatus%28for%3A%29),
and [usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremindersfullaccessusagedescription).

Reminder reads require full-access authorization.

## Discover accounts and lists

| Call or property | Useful behavior |
| --- | --- |
| `calendars(for: .reminder)` | Enumerate accessible reminder lists. Start here for listing lists and per-list reads. |
| `sources` | Enumerate sources, including ones unrelated to reminders. |
| `calendar.source` | Associate a list with its source/account. |
| `sourceIdentifier`, `source.title`, `sourceType` | Identify and describe the account/source. |
| `calendarIdentifier`, `calendar.title` | Identify and name each list without relying on unique names. |
| `calendar(withIdentifier:)` | Resolve a previously discovered list ID. |
| `defaultCalendarForNewReminders()` | Obtain the default destination list; may return nil. |
| `allowsContentModifications` | Check whether reminders in a list can be added, edited, or deleted. |
| `isImmutable`, `isSubscribed`, `cgColor` | Read list editability, subscription status, and color. |

`isImmutable` and `allowsContentModifications` describe different capabilities;
neither guarantees that a requested operation will succeed.

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

Passing nil calendars means all available calendars, not an empty scope. Completed-date
predicates constrain completion dates, not due dates. A nil fetch result is
indeterminate, unlike an empty array.

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

See [EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm),
[EKStructuredLocation](https://developer.apple.com/documentation/eventkit/ekstructuredlocation),
[EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule),
and [recurrence-rule support](https://developer.apple.com/documentation/eventkit/ekcalendaritem/recurrencerules).

Date components distinguish floating zones and all-day dates.

## Identifiers and refresh

Apple warns that `calendarItemIdentifier` can be lost during a full sync.
`calendarItemExternalIdentifier` is a server-provided alternative, but is not
guaranteed unique across copies. `calendarItems(withExternalIdentifier:)` can
therefore return multiple matches. Preserve source/list context when reconciling;
never silently mutate a same-title reminder as a substitute for a missing ID.
See [local identifier](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier)
and [external identifier](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier).

`Notification.Name.EKEventStoreChanged` signals invalidation, not item deltas.
See Apple's [notification guide](https://developer.apple.com/documentation/eventkit/updating-with-notifications).
`refreshSourcesIfNecessary()` does not guarantee completed cloud synchronization.

## Related write calls

Reminder and list writes use these calls:

| Call | Purpose |
| --- | --- |
| `EKReminder(eventStore:)` | Construct a reminder, then assign its calendar and properties. |
| `save(_:commit:)` / `remove(_:commit:)` for reminders | Persist changes or delete a reminder. |
| `EKCalendar(for: .reminder, eventStore:)` | Construct a reminder list; select an appropriate source. |
| `saveCalendar(_:commit:)` / `removeCalendar(_:commit:)` | Persist or delete a list, subject to source capabilities. |
| `commit()` | Save pending changes when using deferred commits. |

See Apple's [creating events and reminders](https://developer.apple.com/documentation/eventkit/creating-events-and-reminders).
Deferred commits are not a transaction or rollback guarantee across multiple
operations. Completing a reminder and setting its completion date are coupled
operations; test recurrence and completion behavior before relying on a faithful
round trip.
