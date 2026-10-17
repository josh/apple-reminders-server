import CoreLocation
import EventKit
import Foundation

enum ReminderClearValue: String, Sendable, CaseIterable {
  case location = "LOCATION"
  case url = "URL"
  case dueDate = "DUE_DATE"
  case allDayDueDate = "ALL_DAY_DUE_DATE"
  case completionDate = "COMPLETION_DATE"
  case recurrence = "RECURRENCE"
  case timeZone = "TIME_ZONE"
  case startDate = "START_DATE"
  case allDayStartDate = "ALL_DAY_START_DATE"
}
enum ReminderAlarmChange: Sendable {
  case absolute(Date)
  case relative(Double)
  case location(title: String?, latitude: Double, longitude: Double, radius: Double, arriving: Bool)
}
struct ReminderChanges: Sendable {
  var name: String?
  var body: String?
  var completed: Bool?
  var flagged: Bool?
  var remindMeDate: Date?
  var timeZone: TimeZone?
  var completionDate: Date?
  var alarms: [ReminderAlarmChange]?
  var recurrence: ReminderRecurrenceChange?
  var priority: Int?
  var location: String?
  var url: URL?
  var due: DateComponents?
  var start: DateComponents?
  var clear: Set<ReminderClearValue> = []
  init() {}
}
enum ReminderMutation: Sendable {
  case create(listID: String?, changes: ReminderChanges)
  case update(id: String, changes: ReminderChanges)
  case delete(id: String)
}

// Mutations honor EventKit authorization and the destination list capabilities.
func executeMutation(_ request: ReminderMutation) throws -> MutationResult<ReminderRecord> {
  try requireAccess()
  let store = EKEventStore()
  let item: EKReminder
  let changes: ReminderChanges?
  switch request {
  case .create(let listID, let patch):
    let list =
      listID.flatMap { store.calendar(withIdentifier: $0) }
      ?? (listID == nil ? store.defaultCalendarForNewReminders() : nil)
    guard let list else { throw ServerError.message("NOT_FOUND: reminder list is unavailable") }
    guard list.allowedEntityTypes.contains(.reminder) else {
      throw ServerError.message("INVALID_ARGUMENT: destination is not a reminder list")
    }
    guard list.allowsContentModifications else {
      throw ServerError.message("READ_ONLY: destination list is not editable")
    }
    guard let name = patch.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ServerError.message("INVALID_ARGUMENT: name must not be blank") }
    item = EKReminder(eventStore: store)
    item.calendar = list
    changes = patch
  case .update(let id, let patch):
    guard let existing = store.calendarItem(withIdentifier: id) as? EKReminder else {
      throw ServerError.message("NOT_FOUND: reminder is unavailable")
    }
    item = existing
    changes = patch
  case .delete(let id):
    guard let existing = store.calendarItem(withIdentifier: id) as? EKReminder else {
      throw ServerError.message("NOT_FOUND: reminder is unavailable")
    }
    item = existing
    changes = nil
  }
  guard let list = item.calendar, list.allowsContentModifications else {
    throw ServerError.message("READ_ONLY: reminder list is not editable")
  }
  guard let patch = changes else {
    let id = item.calendarItemIdentifier
    do { try store.remove(item, commit: true) } catch {
      throw ServerError.message(
        "WRITE_FAILED: EventKit delete failed (code \((error as NSError).code)); refetch before retrying"
      )
    }
    return .deleted(DeletedReminder(deletedId: id))
  }
  if let name = patch.name {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ServerError.message("INVALID_ARGUMENT: name must not be blank")
    }
    item.title = name
  }
  if let priority = patch.priority {
    guard (0...9).contains(priority) else {
      throw ServerError.message("INVALID_ARGUMENT: priority must be 0...9")
    }
    item.priority = priority
  }
  if let body = patch.body { item.notes = body.isEmpty ? nil : body }
  if let value = patch.completed { item.isCompleted = value }
  if let date = patch.completionDate { item.completionDate = date }
  if patch.clear.contains(.completionDate) { item.completionDate = nil }
  if let location = patch.location { item.location = location }
  if let url = patch.url { item.url = url }
  if patch.clear.contains(.location) { item.location = nil }
  if patch.clear.contains(.url) { item.url = nil }
  if patch.clear.contains(.dueDate) || patch.clear.contains(.allDayDueDate) {
    item.dueDateComponents = nil
  }
  if patch.clear.contains(.startDate) || patch.clear.contains(.allDayStartDate) {
    item.startDateComponents = nil
  }
  if let due = patch.due { item.dueDateComponents = due }
  if let start = patch.start { item.startDateComponents = start }
  if patch.timeZone != nil || patch.clear.contains(.timeZone) {
    guard item.startDateComponents != nil || item.dueDateComponents != nil else {
      throw ServerError.message("INVALID_ARGUMENT: timeZone requires a resulting start or due date")
    }
    let target = patch.timeZone ?? .current
    item.startDateComponents = try changingZone(
      item.startDateComponents, to: target, floating: patch.clear.contains(.timeZone))
    item.dueDateComponents = try changingZone(
      item.dueDateComponents, to: target, floating: patch.clear.contains(.timeZone))
  }
  if patch.clear.contains(.recurrence) { item.recurrenceRules = nil }
  if let recurrence = patch.recurrence { item.recurrenceRules = [recurrence.eventKitRule()] }
  if let alarms = patch.alarms {
    item.alarms = alarms.map { value in
      switch value {
      case .absolute(let date): return EKAlarm(absoluteDate: date)
      case .relative(let offset): return EKAlarm(relativeOffset: offset)
      case .location(let title, let latitude, let longitude, let radius, let arriving):
        let alarm = EKAlarm(relativeOffset: 0)
        let location = EKStructuredLocation(title: title ?? "")
        location.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        location.radius = radius
        alarm.structuredLocation = location
        alarm.proximity = arriving ? .enter : .leave
        return alarm
      }
    }
  }
  if item.startDateComponents == nil,
    (item.alarms ?? []).contains(where: {
      $0.absoluteDate == nil && $0.proximity == .none && $0.structuredLocation == nil
    })
  {
    throw ServerError.message(
      "INVALID_ARGUMENT: relative alarms require a start date on the resulting reminder")
  }
  if let start = item.startDateComponents, let due = item.dueDateComponents {
    guard let startDate = mutationDate(start), let dueDate = mutationDate(due) else {
      throw ServerError.message(
        "UNSUPPORTED_OPERATION: cannot validate the existing start/due date combination")
    }
    guard startDate <= dueDate else {
      throw ServerError.message("INVALID_ARGUMENT: start date must not be later than due date")
    }
  }
  let automation = patch.flagged != nil || patch.remindMeDate != nil
  // Compile before committing: syntax failures must not leave an avoidable partial write.
  let script = automation ? try makeReminderWriteScript() : nil
  do { try store.save(item, commit: true) } catch {
    throw ServerError.message(
      "WRITE_FAILED: EventKit save failed (code \((error as NSError).code)); refetch before retrying"
    )
  }
  if let script {
    let id = item.calendarItemIdentifier
    do {
      try writeReminderAutomation(
        script, id: id, listID: list.calendarIdentifier, flagged: patch.flagged,
        alert: patch.remindMeDate)
      store.reset()
      guard let refreshed = store.calendarItem(withIdentifier: id) as? EKReminder else {
        throw ServerError.message("saved reminder is not available for refetch")
      }
      return .saved(try ReminderRecord(refreshed, now: Date(), flagged: patch.flagged))
    } catch {
      throw ServerError.message(
        "WRITE_APPLIED: EventKit saved reminder \(id), but automation or refetch failed: \(error). Automation may have partially applied; refetch this ID before retrying. No rollback was attempted"
      )
    }
  }
  do { return .saved(try ReminderRecord(item, now: Date(), flagged: nil)) } catch {
    throw ServerError.message(
      "WRITE_APPLIED: EventKit saved reminder \(item.calendarItemIdentifier), but response projection failed: \(error). Refetch this ID before retrying"
    )
  }
}

private func mutationDate(_ value: DateComponents) -> Date? {
  guard value.calendar?.identifier == nil || value.calendar?.identifier == .gregorian,
    value.year != nil, value.month != nil, value.day != nil
  else { return nil }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = value.timeZone ?? .current
  guard let date = calendar.date(from: value) else { return nil }
  let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
  guard check.year == value.year, check.month == value.month, check.day == value.day,
    check.hour == (value.hour ?? 0), check.minute == (value.minute ?? 0),
    check.second == (value.second ?? 0)
  else { return nil }
  return date
}

// Timed dates retain their instant; date-only values retain their calendar day.
// Clearing the zone converts timed values to local wall time before making them floating.
private func changingZone(_ value: DateComponents?, to zone: TimeZone, floating: Bool) throws
  -> DateComponents?
{
  guard var value else { return nil }
  guard value.calendar?.identifier == nil || value.calendar?.identifier == .gregorian else {
    throw ServerError.message(
      "UNSUPPORTED_OPERATION: time-zone writes require Gregorian date components")
  }
  guard let instant = mutationDate(value) else {
    throw ServerError.message(
      "UNSUPPORTED_OPERATION: incomplete date or clock-transition gap in time-zone change")
  }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = zone
  if value.hour != nil {
    value = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: instant)
  }
  value.calendar = calendar
  value.timeZone = floating ? nil : zone
  return value
}
