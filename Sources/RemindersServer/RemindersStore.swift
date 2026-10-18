import CoreGraphics
import EventKit
import Foundation

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
    throw ServerError.internalError("EventKit operation timed out after 30 seconds")
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
    throw ServerError.internalError(
      "Reminders access is \(statusName()); explicitly request access at startup or grant it in System Settings"
    )
  }
}
// Classification preserves floating/date-only
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
func authorizeReminders() throws {
  let store = EKEventStore()
  let pending = Pending<Result<Bool, Error>>()
  store.requestFullAccessToReminders { granted, error in
    pending.resolve(
      error.map {
        .failure(
          ServerError.internalError("EventKit authorization failed (code \(($0 as NSError).code))"))
      } ?? .success(granted))
  }
  guard try pending.wait().get() else {
    throw ServerError.internalError("Reminders access was not granted")
  }
  try requireAccess()
}

func fetchInventory(includeFlags: Bool) throws -> Inventory {
  try requireAccess()
  let store = EKEventStore()
  let calendars = store.calendars(for: .reminder).sorted {
    $0.calendarIdentifier < $1.calendarIdentifier
  }
  let lists = calendars.map(ListRecord.init)
  let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
  let defaultListID = lists.contains(where: { $0.id == defaultID }) ? defaultID : nil
  let flags = includeFlags ? try readScriptFlagsOnMainThread() : nil
  var fetched: [EKReminder] = []
  if !calendars.isEmpty {
    let pending = Pending<Result<[EKReminder], Error>>()
    let handle = store.fetchReminders(matching: store.predicateForReminders(in: calendars)) {
      items in
      pending.resolve(
        items.map { .success($0) }
          ?? .failure(
            ServerError.internalError("EventKit returned an indeterminate nil reminder inventory")))
    }
    do { fetched = try pending.wait().get() } catch {
      store.cancelFetchRequest(handle)
      throw error
    }
  }
  try requireAccess()
  let now = Date()
  var seen = Set<String>()
  var reminders: [ReminderRecord] = []
  for item in fetched.sorted(by: { $0.calendarItemIdentifier < $1.calendarItemIdentifier }) {
    guard seen.insert(item.calendarItemIdentifier).inserted else {
      throw ServerError.internalError("EventKit returned duplicate reminder identifiers")
    }
    guard let list = item.calendar,
      calendars.contains(where: { $0.calendarIdentifier == list.calendarIdentifier })
    else { throw ServerError.internalError("Reminder list inventory changed during collection") }
    // Reminders exposes newly saved objects to scripting late; a missing match
    // leaves only that reminder's flag unknown instead of failing the inventory.
    let flagged = flags.flatMap { table in
      UUID(uuidString: item.calendarItemIdentifier).flatMap { table[$0.uuidString] }
    }
    reminders.append(try ReminderRecord(item, now: now, flagged: flagged))
  }
  return Inventory(lists: lists, reminders: reminders, defaultListId: defaultListID)
}

// Protected by main-thread confinement. Nested calls can occur while an Apple
// event or EventKit callback pumps the run loop; fail instead of overlapping state.
private var busy = false
func performRemindersOperation<T>(_ operation: @escaping () throws -> T) throws -> T {
  let work = {
    guard !busy else {
      throw ServerError.internalError("Reminders store is busy with a reentrant request; retry")
    }
    busy = true
    defer { busy = false }
    return try autoreleasepool(invoking: operation)
  }
  if Thread.isMainThread { return try work() }
  return try DispatchQueue.main.sync(execute: work)
}
func remindersRunMainLoop() {
  guard Thread.isMainThread else { return }
  _ = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
  RunLoop.main.run()
}
