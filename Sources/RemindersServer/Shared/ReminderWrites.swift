import AppKit
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
enum ReminderAlarmTrigger: Equatable, Sendable {
  case absolute(Date)
  case relative(Double)
  case location(title: String?, latitude: Double, longitude: Double, radius: Double, arriving: Bool)
}
struct ReminderAlarmChange: Equatable, Sendable {
  let trigger: ReminderAlarmTrigger
  let soundName: String?
  let emailAddress: String?
}
struct ReminderChanges: Equatable, Sendable {
  var listId: String?
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
      if let listID { reminderList(store, id: listID) } else {
        store.defaultCalendarForNewReminders()
      }
    guard let list else { throw ServerError.notFound("reminder list is unavailable") }
    guard changes.name != nil else { throw ServerError.invalidArgument("name must not be blank") }
    item = EKReminder(eventStore: store)
    item.calendar = list
    patch = changes
  case .update(let id, let changes):
    item = try editableReminder(store, id: id)
    patch = changes
    if let listID = patch.listId {
      guard let destination = reminderList(store, id: listID) else {
        throw ServerError.notFound("destination reminder list is unavailable")
      }
      guard destination.allowsContentModifications else {
        throw ServerError.readOnly("destination reminder list is not editable")
      }
      item.calendar = destination
    }
  }
  guard let list = item.calendar, list.allowsContentModifications else {
    throw ServerError.readOnly("reminder list is not editable")
  }
  let listID = list.calendarIdentifier
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
  var requestedDelivery: [AlarmRecord] = []
  if let alarms = patch.alarms {
    let configured = try alarms.map(makeReminderAlarm)
    requestedDelivery =
      configured
      .filter { $0.soundName != nil || $0.emailAddress != nil }.map(AlarmRecord.init)
    item.alarms = configured
  }
  if item.startDateComponents == nil,
    (item.alarms ?? []).contains(where: {
      $0.absoluteDate == nil && $0.proximity == .none && $0.structuredLocation == nil
    })
  {
    throw ServerError.invalidArgument(
      "relative alarms require a start date on the resulting reminder")
  }
  // Native recurrence can advance start and due differently across DST. An
  // unrelated edit must not be blocked by a combination the provider stored.
  let changesDates =
    patch.start != nil || patch.due != nil || patch.timeZone != nil
    || patch.clear.contains(.timeZone)
  if changesDates, let start = item.startDateComponents, let due = item.dueDateComponents {
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
  let savedItem: EKReminder
  let changesCompletion =
    patch.completed != nil || patch.completionDate != nil || patch.clear.contains(.completionDate)
  if patch.listId != nil || !requestedDelivery.isEmpty || changesCompletion {
    let savedID = item.calendarItemIdentifier
    store.reset()
    guard let refreshed = store.calendarItem(withIdentifier: savedID) as? EKReminder else {
      throw ServerError.writeApplied(
        "reminder \(savedID) was saved but is unavailable for verification; refetch before retrying"
      )
    }
    if let destinationID = patch.listId,
      refreshed.calendar?.calendarIdentifier != destinationID
    {
      throw ServerError.writeApplied(
        "reminder \(savedID) was saved, but its destination list could not be verified; refetch this ID before retrying"
      )
    }
    try verifyAlarmDelivery(
      requestedDelivery, stored: (refreshed.alarms ?? []).map(AlarmRecord.init), id: savedID)
    savedItem = refreshed
  } else {
    savedItem = item
  }
  if automation {
    return .automation(
      PendingAutomation(
        reminderID: savedItem.calendarItemIdentifier, listID: listID,
        flagged: patch.flagged, remindMeDate: patch.remindMeDate))
  }
  do { return .finished(try ReminderRecord(savedItem, now: Date(), flagged: nil)) } catch {
    throw ServerError.writeApplied(
      "EventKit saved reminder \(savedItem.calendarItemIdentifier), but response projection failed: \(error). Refetch this ID before retrying"
    )
  }
}

@MainActor
func makeReminderAlarm(_ value: ReminderAlarmChange) throws -> EKAlarm {
  let alarm: EKAlarm
  switch value.trigger {
  case .absolute(let date): alarm = EKAlarm(absoluteDate: date)
  case .relative(let offset): alarm = EKAlarm(relativeOffset: offset)
  case .location(let title, let latitude, let longitude, let radius, let arriving):
    alarm = EKAlarm(relativeOffset: 0)
    let location = EKStructuredLocation(title: title ?? "")
    location.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
    location.radius = radius
    alarm.structuredLocation = location
    alarm.proximity = arriving ? .enter : .leave
  }
  if let sound = value.soundName {
    guard NSSound(named: NSSound.Name(sound)) != nil else {
      throw ServerError.invalidArgument("soundName must name an available system sound")
    }
    alarm.soundName = sound
  }
  if let email = value.emailAddress { alarm.emailAddress = email }
  return alarm
}

// Compare triggers and delivery settings. A sound can accompany a display or audio action.
func verifyAlarmDelivery(_ requested: [AlarmRecord], stored: [AlarmRecord], id: String) throws {
  var unmatched = stored
  for alarm in requested {
    let index = unmatched.firstIndex {
      let actionMatches =
        alarm.soundName != nil
        ? ["display", "audio"].contains($0.action) : $0.action == alarm.action
      return actionMatches && $0.soundName == alarm.soundName
        && $0.emailAddress == alarm.emailAddress
        && $0.absoluteDate == alarm.absoluteDate && $0.relativeOffset == alarm.relativeOffset
        && $0.proximity == alarm.proximity && $0.structuredLocation == alarm.structuredLocation
    }
    guard let index else {
      throw ServerError.writeApplied(
        "reminder \(id) was saved, but the provider did not retain the requested alarm delivery; refetch this ID before retrying"
      )
    }
    unmatched.remove(at: index)
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
