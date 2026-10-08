import CoreGraphics
import EventKit
import Foundation

struct RemindersError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}
func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

// The data-access entrypoint serializes all EventKit and AppleScript work on main.
// The callback handoff is locked because EventKit may complete on another queue.
final class Pending<Value> {
  private let lock = NSLock()
  private var result: Value?
  func resolve(_ value: Value) {
    lock.lock()
    defer { lock.unlock() }
    result = value
  }
  func current() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
  func wait() throws -> Value {
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let value = current() { return value }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    if let value = current() { return value }
    throw RemindersError("EventKit operation timed out after 30 seconds")
  }
}
func statusName() -> String {
  switch EKEventStore.authorizationStatus(for: .reminder) {
  case .notDetermined: return "notDetermined"
  case .restricted: return "restricted"
  case .denied: return "denied"
  case .fullAccess: return "fullAccess"
  case .writeOnly: return "writeOnly"
  @unknown default: return "unknown"
  }
}
func requireAccess() throws {
  guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
    throw RemindersError(
      "Reminders access is \(statusName()); explicitly request access at startup or grant it in System Settings"
    )
  }
}
func components(_ value: DateComponents?) -> Any {
  guard let value else { return NSNull() }
  return [
    "calendar": nullable(value.calendar.map { String(describing: $0.identifier) }),
    "timeZone": nullable(value.timeZone?.identifier),
    "floating": value.timeZone == nil,
    "allDay": [value.hour, value.minute, value.second, value.nanosecond].allSatisfy { $0 == nil },
    "isLeapMonth": value.isLeapMonth ?? false,
    "era": nullable(value.era), "year": nullable(value.year), "month": nullable(value.month),
    "day": nullable(value.day),
    "hour": nullable(value.hour), "minute": nullable(value.minute),
    "second": nullable(value.second), "nanosecond": nullable(value.nanosecond),
    "weekday": nullable(value.weekday), "weekdayOrdinal": nullable(value.weekdayOrdinal),
    "quarter": nullable(value.quarter),
    "weekOfMonth": nullable(value.weekOfMonth), "weekOfYear": nullable(value.weekOfYear),
    "yearForWeekOfYear": nullable(value.yearForWeekOfYear),
  ] as [String: Any]
}
func listJSON(_ list: EKCalendar) -> [String: Any] {
  let color = list.cgColor?.converted(
    to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
  let hex = color?.components.flatMap { values -> String? in
    guard values.count == 4 else { return nil }
    return "#"
      + values.map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
  }
  return [
    "color": nullable(hex), "id": list.calendarIdentifier, "title": list.title,
    "source": [
      "id": list.source.sourceIdentifier, "title": list.source.title,
      "type": list.source.sourceType.rawValue,
    ],
    "allowsContentModifications": list.allowsContentModifications, "immutable": list.isImmutable,
    "subscribed": list.isSubscribed,
  ]
}
// Classification is shared by all metrics hosts, preserving floating/date-only
// semantics. Unsupported or non-roundtripping components are unknown, not zero.
private func resolvedDueDate(_ components: DateComponents, reporting: Calendar) -> (
  date: Date, timed: Bool
)? {
  guard let year = components.year, let month = components.month, let day = components.day,
    (1...9999).contains(year), components.era == nil || components.era == 1
  else { return nil }
  if let identifier = components.calendar?.identifier, identifier != .gregorian { return nil }
  let hour = components.hour
  if hour == nil
    && [components.minute, components.second, components.nanosecond].contains(where: { $0 != nil })
  {
    return nil
  }
  if let hour, !(0...23).contains(hour) { return nil }
  if let minute = components.minute, !(0...59).contains(minute) { return nil }
  if let second = components.second, !(0...59).contains(second) { return nil }
  if let nano = components.nanosecond, !(0...999_999_999).contains(nano) { return nil }
  var source = Calendar(identifier: .gregorian)
  source.timeZone = hour == nil ? reporting.timeZone : (components.timeZone ?? reporting.timeZone)
  var parts = DateComponents(year: year, month: month, day: day)
  if let hour {
    parts.hour = hour
    parts.minute = components.minute ?? 0
    parts.second = components.second ?? 0
    parts.nanosecond = components.nanosecond ?? 0
  }
  guard let date = source.date(from: parts) else { return nil }
  let check = source.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
  guard check.year == year, check.month == month, check.day == day,
    hour == nil
      || (check.hour == hour && check.minute == parts.minute && check.second == parts.second)
  else { return nil }
  return (date, hour != nil)
}
func dueStatus(_ components: DateComponents?, now: Date) -> String? {
  guard let components else { return "unscheduled" }
  var reporting = Calendar(identifier: .gregorian)
  reporting.timeZone = .current
  guard let resolved = resolvedDueDate(components, reporting: reporting) else { return nil }
  if resolved.timed && resolved.date < now { return "overdue" }
  let comparison = reporting.compare(resolved.date, to: now, toGranularity: .day)
  return comparison == .orderedAscending
    ? "overdue" : comparison == .orderedSame ? "today" : "future"
}
// Calendar-day searches use the same resolution rules as deadline metrics.
func dueDay(_ components: DateComponents?) -> String? {
  guard let components else { return nil }
  var reporting = Calendar(identifier: .gregorian)
  reporting.timeZone = .current
  guard let resolved = resolvedDueDate(components, reporting: reporting) else { return nil }
  let parts = reporting.dateComponents([.year, .month, .day], from: resolved.date)
  guard let year = parts.year, let month = parts.month, let day = parts.day,
    (1...9999).contains(year)
  else { return nil }
  return String(format: "%04d-%02d-%02d", year, month, day)
}
// Raw read-only recurrence rules are preserved; no future instances are generated.
func recurrenceJSON(_ rule: EKRecurrenceRule, stamp: (Date?) -> Any) -> [String: Any] {
  let frequency: String
  switch rule.frequency {
  case .daily: frequency = "daily"
  case .weekly: frequency = "weekly"
  case .monthly: frequency = "monthly"
  case .yearly: frequency = "yearly"
  @unknown default: frequency = "unknown"
  }
  func integers(_ values: [NSNumber]?) -> [Int] { (values ?? []).map { $0.intValue } }
  let end: Any =
    rule.recurrenceEnd.map {
      ["endDate": stamp($0.endDate), "occurrenceCount": $0.occurrenceCount] as [String: Any]
    } ?? NSNull()
  return [
    "frequency": frequency, "calendarIdentifier": rule.calendarIdentifier,
    "interval": rule.interval, "firstDayOfTheWeek": rule.firstDayOfTheWeek,
    "daysOfTheWeek": (rule.daysOfTheWeek ?? []).map {
      ["dayOfTheWeek": $0.dayOfTheWeek.rawValue, "weekNumber": $0.weekNumber]
    },
    "daysOfTheMonth": integers(rule.daysOfTheMonth), "daysOfTheYear": integers(rule.daysOfTheYear),
    "weeksOfTheYear": integers(rule.weeksOfTheYear),
    "monthsOfTheYear": integers(rule.monthsOfTheYear),
    "setPositions": integers(rule.setPositions), "end": end,
  ]
}
func alarmJSON(_ alarm: EKAlarm, stamp: (Date?) -> Any) -> [String: Any] {
  let proximity: String
  switch alarm.proximity {
  case .none: proximity = "none"
  case .enter: proximity = "enter"
  case .leave: proximity = "leave"
  @unknown default: proximity = "unknown"
  }
  let location: Any =
    alarm.structuredLocation.map {
      [
        "title": nullable($0.title), "latitude": nullable($0.geoLocation?.coordinate.latitude),
        "longitude": nullable($0.geoLocation?.coordinate.longitude), "radius": $0.radius,
      ] as [String: Any]
    } ?? NSNull()
  return [
    "absoluteDate": stamp(alarm.absoluteDate), "relativeOffset": alarm.relativeOffset,
    "proximity": proximity, "structuredLocation": location,
  ]
}
func reminderJSON(_ item: EKReminder, now: Date, flagged: Bool?) -> [String: Any] {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  func stamp(_ date: Date?) -> Any { nullable(date.map { formatter.string(from: $0) }) }
  return [
    "id": item.calendarItemIdentifier, "externalId": nullable(item.calendarItemExternalIdentifier),
    "listId": nullable(item.calendar?.calendarIdentifier), "title": nullable(item.title),
    "notes": nullable(item.notes),
    "completed": item.isCompleted, "flagged": nullable(flagged), "priority": item.priority,
    "completionDate": stamp(item.completionDate), "creationDate": stamp(item.creationDate),
    "lastModifiedDate": stamp(item.lastModifiedDate),
    "startDateComponents": components(item.startDateComponents),
    "dueDateComponents": components(item.dueDateComponents),
    "location": nullable(item.location), "url": nullable(item.url?.absoluteString),
    "dueStatus": nullable(dueStatus(item.dueDateComponents, now: now)),
    "dueDay": nullable(dueDay(item.dueDateComponents)),
    "alarms": (item.alarms ?? []).map { alarmJSON($0, stamp: stamp) },
    "recurrenceRules": (item.recurrenceRules ?? []).map { recurrenceJSON($0, stamp: stamp) },
  ]
}
func execute(command: String, listID: String?) throws -> [String: Any] {
  if command.hasPrefix("script-") {
    try requireAccess()
    return try readScriptProperty(command)
  }
  guard
    [
      "status", "authorize", "lists", "defaults", "reminders", "reminders-base", "snapshot",
      "snapshot_plain",
    ].contains(command)
  else { throw RemindersError("Unknown Reminders command") }
  if command == "status" { return ["authorization": statusName()] }
  let store = EKEventStore()
  if command == "authorize" {
    let pending = Pending<Result<Bool, Error>>()
    store.requestFullAccessToReminders { granted, error in
      pending.resolve(
        error.map {
          .failure(RemindersError("EventKit authorization failed (code \(($0 as NSError).code))"))
        } ?? .success(granted))
    }
    guard try pending.wait().get() else { throw RemindersError("Reminders access was not granted") }
    try requireAccess()
    return ["authorization": statusName()]
  }
  try requireAccess()
  var calendars = store.calendars(for: .reminder).sorted {
    $0.calendarIdentifier < $1.calendarIdentifier
  }
  if command == "defaults" {
    let id = store.defaultCalendarForNewReminders()?.calendarIdentifier
    try requireAccess()
    return ["defaultListId": nullable(id)]
  }
  if let listID {
    guard let list = calendars.first(where: { $0.calendarIdentifier == listID }) else {
      throw RemindersError("No accessible reminder list matches the requested ID")
    }
    calendars = [list]
  }
  let lists = calendars.map(listJSON)
  let defaultListID: String?
  if ["lists", "snapshot", "snapshot_plain"].contains(command),
    let id = store.defaultCalendarForNewReminders()?.calendarIdentifier,
    calendars.contains(where: { $0.calendarIdentifier == id })
  {
    defaultListID = id
  } else {
    defaultListID = nil
  }
  if command == "lists" {
    try requireAccess()
    return ["lists": lists, "defaultListId": nullable(defaultListID)]
  }
  let enriched = ["reminders", "snapshot"].contains(command)
  let flags = enriched ? try readScriptFlagsOnMainThread() : nil
  var fetched: [EKReminder] = []
  if !calendars.isEmpty {
    let pending = Pending<Result<[EKReminder], Error>>()
    let handle = store.fetchReminders(matching: store.predicateForReminders(in: calendars)) {
      items in
      pending.resolve(
        items.map { .success($0) }
          ?? .failure(RemindersError("EventKit returned an indeterminate nil reminder inventory")))
    }
    do { fetched = try pending.wait().get() } catch {
      store.cancelFetchRequest(handle)
      throw error
    }
  }
  try requireAccess()
  let now = Date()
  var seen = Set<String>()
  var reminders: [[String: Any]] = []
  for item in fetched.sorted(by: { $0.calendarItemIdentifier < $1.calendarItemIdentifier }) {
    guard seen.insert(item.calendarItemIdentifier).inserted else {
      throw RemindersError("EventKit returned duplicate reminder identifiers")
    }
    guard let list = item.calendar,
      calendars.contains(where: { $0.calendarIdentifier == list.calendarIdentifier })
    else { throw RemindersError("Reminder list inventory changed during collection") }
    let flagged: Bool?
    if let flags {
      guard let key = UUID(uuidString: item.calendarItemIdentifier)?.uuidString,
        let value = flags[key]
      else {
        throw RemindersError("EventKit reminder has no unambiguous AppleScript flag match; retry")
      }
      flagged = value
    } else {
      flagged = nil
    }
    reminders.append(reminderJSON(item, now: now, flagged: flagged))
  }
  if command == "snapshot" || command == "snapshot_plain" {
    return ["lists": lists, "reminders": reminders, "defaultListId": nullable(defaultListID)]
  }
  return ["reminders": reminders]
}

// Protected by main-thread confinement. Nested calls can occur while an Apple
// event or EventKit callback pumps the run loop; fail instead of overlapping state.
private var busy = false
// Swift-only entrypoint: data and errors use Swift ownership throughout.
func performRemindersOperation<T>(_ operation: @escaping () throws -> T) throws -> T {
  let work = {
    guard !busy else {
      throw RemindersError("Reminders store is busy with a reentrant request; retry")
    }
    busy = true
    defer { busy = false }
    return try autoreleasepool(invoking: operation)
  }
  if Thread.isMainThread { return try work() }
  return try DispatchQueue.main.sync(execute: work)
}
func remindersRead(_ command: String, listID: String? = nil) throws -> Data {
  try performRemindersOperation {
    try JSONSerialization.data(
      withJSONObject: execute(command: command, listID: listID), options: [.sortedKeys])
  }
}
func remindersRunMainLoop() {
  guard Thread.isMainThread else { return }
  _ = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
  RunLoop.main.run()
}
