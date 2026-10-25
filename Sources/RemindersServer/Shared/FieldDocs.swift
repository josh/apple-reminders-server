// Field descriptions shared by the GraphQL schema and the MCP catalog.
enum FieldDocs {
  enum Account {
    static let id = "Unique identifier of the account. Treat this value as opaque."
    static let name = "The name of the account."
  }
  enum ListFilter {
    static let query = "Case-insensitive substring of the list name."
    static let accountIds =
      "Match lists in any of these accounts, intersected with the parent scope; [] matches nothing."
    static let allowsContentModifications = "Match whether reminders in the list can be modified."
    static let subscribed = "Match subscribed or unsubscribed lists."
  }
  enum ListOrder {
    static let direction =
      "Direction of name ordering. Ties use identifier order; without orderBy, lists use identifier order."
  }
  enum ListPage {
    static let items = "Lists in this page."
    static let totalCount = "Number of matching lists before pagination."
  }
  enum ReminderList {
    static let id = "Unique identifier of the list. Treat this value as opaque."
    static let name = "The name of the list."
    static let allowsContentModifications =
      "Whether reminders can be added, edited, and deleted in this list."
    static let allowsListModifications =
      "Whether the list's own properties can be edited and the list deleted: it must allow content changes and be neither immutable nor subscribed."
    static let subscribed = "Whether the list is a subscription."
    static let color = "The color of the list as an sRGB #RRGGBBAA hex string."
  }
  enum ReminderOrder {
    static let field = "Property to sort by."
    static let direction =
      "Direction of ordering. Nulls sort last either way and ties use identifier order; without orderBy, reminders use identifier order."
  }
  enum ReminderFilter {
    static let query = "Match text in the reminder name or notes."
    static let accountIds = "Match reminders belonging to these accounts; [] matches nothing."
    static let hasDueDate = "Match reminders with or without a timed or all-day deadline."
    static let dueFrom = "Inclusive lower bound on the deadline."
    static let listIds = "Match reminders belonging to these lists; [] matches nothing."
    static let priorities = "Match any of these exact numeric priorities; [] matches nothing."
    static let dueStatus = "Match a deadline status, independent of completion."
    static let dueOnOrAfter =
      "Inclusive lower deadline bound as YYYY-MM-DD, using the host zone for timed deadlines. Do not mix timestamp and calendar-day bounds."
    static let dueBefore =
      "Exclusive upper deadline bound: timestamp or YYYY-MM-DD. Do not mix timestamp and calendar-day bounds."
    static let completed = "Match completed or incomplete reminders; omission includes both."
  }
  enum ReminderPage {
    static let items = "Reminders in this page."
    static let totalCount = "Number of matching reminders before pagination."
  }
  enum Reminder {
    static let id = "Unique identifier of the reminder. Treat this value as opaque."
    static let name = "The name of the reminder."
    static let body = "The notes attached to the reminder."
    static let completed = "Whether the reminder is marked completed."
    static let priority = "The priority of the reminder: 0 none, 1–4 high, 5 medium, or 6–9 low."
    static let creationDate = "The date and time the reminder was created."
    static let completionDate = "The date and time the reminder was completed."
    static let modificationDate = "The date and time the reminder was last modified."
    static let location = "Descriptive location text, separate from location-triggered alarms."
    static let dueDay =
      "The deadline's calendar day: timed deadlines in the host zone, all-day deadlines as stored. Null when undated or unclassifiable."
    static let listId = "Identifier of the owning list."
    static let url =
      "An associated absolute URL; does not promise a rich-link preview in Reminders."
    static let startDateComponents = "The stored start date components."
    static let dueDateComponents = "The stored due date components."
    static let dueStatus = "Deadline status, independent of completion."
    static let rawAlarms =
      "Alarms exactly as stored, including triggers the alarms union cannot represent."
    static let recurrenceRules = "Recurrence rules exactly as stored; empty when none."
    static let allDayDueDate =
      "The calendar date on which the reminder is due, without a time of day."
    static let allDayStartDate = "A date-only start, without a time of day."
  }
  enum RawAlarm {
    static let absoluteDate = "Absolute trigger time, when set."
    static let relativeOffset =
      "Seconds from the start date. Zero alone does not distinguish absolute and relative triggers."
    static let proximity = "none, enter, leave, or unknown."
    static let structuredLocation = "The location of a geofence trigger, when set."
  }
  enum StructuredLocation {
    static let title = "Display name of the location."
    static let latitude = "Latitude in degrees, when set."
    static let longitude = "Longitude in degrees, when set."
    static let radius = "Radius in meters; zero means the system default."
  }
  enum AbsoluteAlarm {
    static let at = "The date and time at which the alert triggers."
  }
  enum RelativeAlarm {
    static let offsetSeconds =
      "Seconds from the start date: negative before, zero at, positive after."
  }
  enum LocationAlarm {
    static let geofence = "Region and direction that trigger the alert."
  }
  enum Geofence {
    static let title = "Optional display name of the location."
    static let latitude = "Latitude in degrees, between -90 and 90."
    static let longitude = "Longitude in degrees, between -180 and 180."
    static let radiusMeters =
      "Radius in meters. Zero requests the system default; positive values request a minimum radius."
    static let proximity = "Whether entering or leaving the region triggers the alert."
  }
  enum RecurrenceRule {
    static let frequency = "daily, weekly, monthly, yearly, or unknown."
    static let calendarIdentifier = "Calendar the rule is evaluated in."
    static let interval = "Frequency units between occurrences."
    static let firstDayOfTheWeek = "First day of the week, Sunday = 1; zero is unset."
    static let daysOfTheWeek = "Weekday constraints; empty when unconstrained."
    static let end = "When repetition stops; null for no end."
    static let daysOfTheMonth = "Selector values; empty when unconstrained."
    static let daysOfTheYear = "Selector values; empty when unconstrained."
    static let weeksOfTheYear = "Selector values; empty when unconstrained."
    static let monthsOfTheYear = "Selector values; empty when unconstrained."
    static let setPositions = "Selector values; empty when unconstrained."
  }
  enum RecurrenceDay {
    static let dayOfTheWeek = "Weekday, Sunday = 1."
    static let weekNumber = "Signed ordinal; zero means every occurrence."
  }
  enum RecurrenceEnd {
    static let endDate = "End timestamp, when set."
    static let occurrenceCount = "Number of occurrences; zero when unset."
  }
  enum Schedule {
    static let frequency = "The unit of repetition."
    static let interval = "Positive number of frequency units between occurrences."
    static let daysOfWeek =
      "Weekday constraints. Null means unconstrained. Not allowed for daily rules."
    static let end = "When repetition stops; null means no specified end."
    static let daysOfMonth =
      "Days 1..31 or -31..-1 counting backward from the end of the month. Monthly rules only."
    static let monthsOfYear = "Months 1..12. Yearly rules only."
    static let weeksOfYear =
      "Week numbers 1..53 or -53..-1 counting backward from year end. Yearly rules only."
    static let daysOfYear =
      "Year days 1..366 or -366..-1 counting backward from year end. Yearly rules only."
    static let setPositions =
      "Select positions 1..366 or -366..-1 from occurrences matching the other constraints in each period. Requires another selector."
  }
  enum ScheduleDay {
    static let day = "The weekday to match."
    static let ordinal =
      "Occurrence of this weekday: 1 is first, -1 last; omit for every occurrence. Valid range -53..53 excluding zero; non-null ordinals require monthly or yearly frequency."
  }
  enum ScheduleEnd {
    static let until = "Inclusive end timestamp; mutually exclusive with count."
    static let count = "Positive number of occurrences; mutually exclusive with until."
  }
  enum ListSummary {
    static let total = "All reminders in the list, including completed ones."
    static let completed = "Completed reminders."
    static let incomplete = "Incomplete reminders."
    static let overdue = "Incomplete reminders whose deadline has passed."
    static let scheduled = "Reminders with a due date, including completed ones."
    static let recurring = "Reminders with recurrence rules, including completed ones."
    static let withAlarms = "Reminders with alarms, including completed ones."
  }
  enum CreateListInput {
    static let name = "Name of the new list."
    static let color = "Opaque sRGB list color: #RRGGBB or #RRGGBBFF."
    static let emblem = "Emblem icon name."
    static let accountId = "Account in which to create the list."
  }
  enum ListPatch {
    static let name = "The new name of the list."
    static let color = "The new opaque sRGB list color: #RRGGBB or #RRGGBBFF."
    static let emblem = "The new emblem icon name for the list."
  }
  enum DeleteResult {
    static let deletedId = "The deleted object's identifier."
  }
  enum CreateReminderInput {
    static let name = "Name of the new reminder."
    static let body = "Notes to attach to the reminder."
    static let priority = "Priority from 0 through 9."
    static let location =
      "Unsupported: Reminders does not keep free-text locations, so writes are rejected. Use a geofence alarm."
    static let url = Reminder.url
    static let dueDate =
      "A deadline including a time of day. Reminders may also set the start date and alert date to it."
    static let allDayDueDate =
      "A date-only deadline; mutually exclusive with dueDate. Reminders may also add a start at local midnight."
    static let startDate =
      "The date and time at which work on the reminder starts. It cannot be later than the due date."
    static let allDayStartDate =
      "Unsupported: date-only start writes are rejected because storage does not preserve them. Use startDate."
    static let timeZone =
      "IANA time-zone identifier for the start and due dates, which requires at least one of them; omission stores timed dates in UTC."
    static let flagged = "Whether to flag the new reminder."
    static let remindMeDate =
      "Date and time at which to remind the user; cannot be combined with alarms, start, due, or timeZone."
    static let alarms =
      "Alerts to configure; omission or an empty list configures no explicit alerts."
    static let recurrence = "Repeating schedule; omission creates a non-repeating reminder."
    static let listId =
      "Destination list; omission uses the default list. No default produces an error."
  }
  enum ReminderAlarmInput {
    static let absoluteDate = "Trigger at this instant."
    static let relativeOffsetSeconds =
      "Seconds from the reminder's start date; negative means before. Requires a resulting start date."
    static let geofence = "Trigger on arrival at or departure from this region."
  }
  enum ReminderPatch {
    static let name = "The new name of the reminder."
    static let body = "The new notes attached to the reminder. An empty string removes the notes."
    static let priority = "Set the priority: 0 none, 1–4 high, 5 medium, or 6–9 low."
    static let location = CreateReminderInput.location
    static let url = Reminder.url
    static let dueDate =
      "Set the due date and time. Cannot be combined with allDayDueDate. Reminders may also set the start date and alert date to it."
    static let allDayDueDate =
      "Set a date-only deadline. Cannot be combined with dueDate. Reminders may also add a start at local midnight."
    static let startDate = CreateReminderInput.startDate
    static let allDayStartDate = CreateReminderInput.allDayStartDate
    static let timeZone =
      "Set an IANA time-zone identifier; requires a resulting start or due date. Use clearFields for floating/local interpretation."
    static let flagged = "Set whether the reminder is flagged, independently of priority."
    static let remindMeDate =
      "Set the date and time at which to remind the user. Cannot be combined with date, time-zone, or alarm changes, or cleared."
    static let alarms = "Replace all configured alerts. An empty list removes all alerts."
    static let recurrence = "Replace the repeating schedule. Use clearFields to stop repetition."
    static let completionDate =
      "Set the date and time the reminder was completed, which marks it completed. Cannot be combined with completed."
    static let completed =
      "Whether to mark the reminder completed. Cannot be combined with completionDate changes."
    static let clearFields =
      "Remove these values. Omission preserves them; explicit null is rejected. Do not set and clear the same field, or clear both forms of one date."
  }
}
