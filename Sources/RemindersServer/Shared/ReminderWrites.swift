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

  var description: String {
    switch self {
    case .location: "Unsupported: Reminders does not keep free-text locations."
    case .url: "Remove the associated URL."
    case .dueDate: "Remove the timed due date."
    case .allDayDueDate: "Remove the all-day due date."
    case .completionDate: "Remove the completion date."
    case .recurrence: "Stop repetition."
    case .timeZone: "Use floating/local time-zone interpretation."
    case .startDate: "Remove the timed start date."
    case .allDayStartDate: "Remove the all-day start date."
    }
  }
}
enum ReminderAlarmChange: Equatable, Sendable {
  case absolute(Date)
  case relative(Double)
  case location(title: String?, latitude: Double, longitude: Double, radius: Double, arriving: Bool)
}
struct ReminderChanges: Equatable, Sendable {
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
  var url: URL?
  var due: DateComponents?
  var start: DateComponents?
  var clear: Set<ReminderClearValue> = []
}
enum ReminderWrite: Sendable {
  case create(listID: String?, changes: ReminderChanges)
  case update(id: String, changes: ReminderChanges)
}

// Flag and alert changes apply through Reminders automation after the EventKit save.
struct PendingAutomation: Sendable {
  let reminderID: String
  let listID: String
  let flagged: Bool?
  let remindMeDate: Date?
}
enum ReminderWritePhase: Sendable {
  case finished(ReminderRecord)
  case automation(PendingAutomation)
}

// Writes honor EventKit authorization and the destination list capabilities.
@MainActor
func executeReminderWrite(_ request: ReminderWrite) throws -> ReminderWritePhase {
  try requireAccess()
  let store = EKEventStore()
  let item: EKReminder
  let patch: ReminderChanges
  switch request {
  case .create(let listID, let changes):
    let list =
      listID.flatMap { reminderList(store, id: $0) }
      ?? (listID == nil ? store.defaultCalendarForNewReminders() : nil)
    guard let list else { throw ServerError.notFound("reminder list is unavailable") }
    guard changes.name != nil else { throw ServerError.invalidArgument("name must not be blank") }
    item = EKReminder(eventStore: store)
    item.calendar = list
    patch = changes
  case .update(let id, let changes):
    item = try editableReminder(store, id: id)
    patch = changes
  }
  guard let list = item.calendar, list.allowsContentModifications else {
    throw ServerError.readOnly("reminder list is not editable")
  }
  if let name = patch.name {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ServerError.invalidArgument("name must not be blank")
    }
    item.title = name
  }
  if let priority = patch.priority {
    guard (0...9).contains(priority) else {
      throw ServerError.invalidArgument("priority must be 0...9")
    }
    item.priority = priority
  }
  if let body = patch.body { item.notes = body.isEmpty ? nil : body }
  if let value = patch.completed { item.isCompleted = value }
  if let date = patch.completionDate { item.completionDate = date }
  if patch.clear.contains(.completionDate) { item.completionDate = nil }
  if let url = patch.url { item.url = url }
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
      throw ServerError.invalidArgument("timeZone requires a resulting start or due date")
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
    throw ServerError.invalidArgument(
      "relative alarms require a start date on the resulting reminder")
  }
  if let start = item.startDateComponents, let due = item.dueDateComponents {
    guard let startDate = resolvedInstant(start), let dueDate = resolvedInstant(due) else {
      throw ServerError.unsupportedOperation(
        "cannot validate the existing start/due date combination")
    }
    guard startDate <= dueDate else {
      throw ServerError.invalidArgument("start date must not be later than due date")
    }
  }
  let automation = patch.flagged != nil || patch.remindMeDate != nil
  // Compile before committing: syntax failures must not leave an avoidable partial write.
  if automation { _ = try compile(.applyChanges) }
  do { try store.save(item, commit: true) } catch {
    throw ServerError.writeFailed(
      "EventKit save failed (code \((error as NSError).code)); refetch before retrying"
    )
  }
  if automation {
    return .automation(
      PendingAutomation(
        reminderID: item.calendarItemIdentifier, listID: list.calendarIdentifier,
        flagged: patch.flagged, remindMeDate: patch.remindMeDate))
  }
  do { return .finished(try ReminderRecord(item, now: Date(), flagged: nil)) } catch {
    throw ServerError.writeApplied(
      "EventKit saved reminder \(item.calendarItemIdentifier), but response projection failed: \(error). Refetch this ID before retrying"
    )
  }
}

@MainActor
func executeReminderDelete(id: String) throws -> DeletedReminder {
  try requireAccess()
  let store = EKEventStore()
  let item = try editableReminder(store, id: id)
  let deletedID = item.calendarItemIdentifier
  do { try store.remove(item, commit: true) } catch {
    throw ServerError.writeFailed(
      "EventKit delete failed (code \((error as NSError).code)); refetch before retrying"
    )
  }
  return DeletedReminder(deletedId: deletedID)
}

@MainActor
private func editableReminder(_ store: EKEventStore, id: String) throws -> EKReminder {
  guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
    throw ServerError.notFound("reminder is unavailable")
  }
  guard let list = item.calendar, list.allowsContentModifications else {
    throw ServerError.readOnly("reminder list is not editable")
  }
  return item
}

// One automation attempt on an already-saved reminder. AutomationNotReady means
// Reminders has not exposed the object yet; every other failure is final.
@MainActor
func applyReminderAutomation(_ pending: PendingAutomation) throws -> ReminderRecord {
  try requireAccess()
  let store = EKEventStore()
  guard store.calendarItem(withIdentifier: pending.reminderID) is EKReminder else {
    throw ServerError.internalError("reminder was removed before automation could apply")
  }
  try writeReminderAutomation(
    id: pending.reminderID, listID: pending.listID, flagged: pending.flagged,
    alert: pending.remindMeDate)
  store.reset()
  guard let refreshed = store.calendarItem(withIdentifier: pending.reminderID) as? EKReminder
  else { throw ServerError.internalError("saved reminder is not available for refetch") }
  return try ReminderRecord(refreshed, now: Date(), flagged: pending.flagged)
}

private func resolvedInstant(_ value: DateComponents) -> Date? {
  (try? projectDate(ComponentDate(value)))?.instant
}

// Timed dates retain their instant; date-only values retain their calendar day.
// Clearing the zone converts timed values to local wall time before making them floating.
private func changingZone(_ value: DateComponents?, to zone: TimeZone, floating: Bool) throws
  -> DateComponents?
{
  guard var value else { return nil }
  guard value.calendar?.identifier == nil || value.calendar?.identifier == .gregorian else {
    throw ServerError.unsupportedOperation(
      "time-zone writes require Gregorian date components")
  }
  guard let instant = resolvedInstant(value) else {
    throw ServerError.unsupportedOperation(
      "incomplete date or clock-transition gap in time-zone change")
  }
  if value.hour != nil {
    value = gregorianComponents(instant, in: zone)
  } else {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    value.calendar = calendar
  }
  value.timeZone = floating ? nil : zone
  return value
}

struct ClearCompletedResult: Encodable, Sendable {
  let listId: String
  let deletedCount: Int
}

@MainActor
func clearCompletedReminders(listID: String) async throws -> ClearCompletedResult {
  guard !listID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw ServerError.invalidArgument("listId required")
  }
  try requireAccess()
  let store = EKEventStore()
  guard let list = reminderList(store, id: listID) else {
    throw ServerError.notFound("reminder list is unavailable")
  }
  guard list.allowsContentModifications else {
    throw ServerError.readOnly("reminder list is not editable")
  }
  let predicate = store.predicateForCompletedReminders(
    withCompletionDateStarting: nil, ending: nil, calendars: [list])
  let items = try await fetchReminders(store, matching: predicate)
  try requireAccess()
  guard
    items.allSatisfy({
      $0.isCompleted && $0.calendar?.calendarIdentifier == listID
        && $0.calendar?.allowsContentModifications == true
    })
  else {
    throw ServerError.internalError("Reminder list changed during read; retry")
  }
  guard !items.isEmpty else { return ClearCompletedResult(listId: listID, deletedCount: 0) }
  do {
    for item in items { try store.remove(item, commit: false) }
    try store.commit()
  } catch {
    store.reset()
    throw ServerError.writeFailed(
      "EventKit clear completed failed (code \((error as NSError).code)); refetch before retrying"
    )
  }
  return ClearCompletedResult(listId: listID, deletedCount: items.count)
}
