import CoreGraphics
import EventKit
import Foundation

// EventKit and AppleScript run on the main actor. EventKit calls back on an
// arbitrary queue, and cancelling a fetch suppresses its callback, so the waiting
// task settles its own continuation exactly once: on completion, cancellation, or
// the timeout. Only Sendable records leave the main actor.
private final class Settled<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var outcome: Result<Value, Error>?
  private var cancel: (() -> Void)?
  private var aborted = false

  func attach(_ continuation: CheckedContinuation<Value, Error>) {
    lock.lock()
    if let outcome {
      lock.unlock()
      continuation.resume(with: outcome)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }
  func resume(_ result: Result<Value, Error>) {
    lock.lock()
    guard outcome == nil else { return lock.unlock() }
    outcome = result
    let continuation = self.continuation
    self.continuation = nil
    cancel = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
  func onCancel(_ handler: @escaping () -> Void) {
    lock.lock()
    guard !aborted else {
      lock.unlock()
      return handler()
    }
    cancel = handler
    lock.unlock()
  }
  func abort() {
    lock.lock()
    aborted = true
    let handler = cancel
    cancel = nil
    lock.unlock()
    handler?()
    resume(.failure(CancellationError()))
  }
}
@MainActor
private func settleOnce<Value>(_ start: (Settled<Value>) -> Void) async throws -> Value {
  let settled = Settled<Value>()
  let timeout = Task {
    try await Task.sleep(for: .seconds(30))
    settled.resume(
      .failure(ServerError.internalError("EventKit operation timed out after 30 seconds")))
  }
  defer { timeout.cancel() }
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      settled.attach(continuation)
      start(settled)
    }
  } onCancel: {
    settled.abort()
  }
}
@MainActor
func fetchReminders(_ store: EKEventStore, matching predicate: NSPredicate) async throws
  -> [EKReminder]
{
  try await settleOnce { settled in
    let handle = store.fetchReminders(matching: predicate) { items in
      guard let items else {
        return settled.resume(
          .failure(
            ServerError.internalError("EventKit returned an indeterminate nil reminder inventory")))
      }
      settled.resume(.success(items))
    }
    settled.onCancel { DispatchQueue.main.async { store.cancelFetchRequest(handle) } }
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
@MainActor
func authorizeReminders() async throws {
  let store = EKEventStore()
  let granted: Bool = try await settleOnce { settled in
    store.requestFullAccessToReminders { granted, error in
      if let error {
        settled.resume(
          .failure(
            ServerError.internalError(
              "EventKit authorization failed (code \((error as NSError).code))")))
      } else {
        settled.resume(.success(granted))
      }
    }
  }
  guard granted else { throw ServerError.internalError("Reminders access was not granted") }
  try requireAccess()
}

@MainActor
func readInventory() async throws -> Inventory {
  try requireAccess()
  let store = EKEventStore()
  let calendars = store.calendars(for: .reminder).sorted {
    $0.calendarIdentifier < $1.calendarIdentifier
  }
  let lists = calendars.map(ListRecord.init)
  let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
  let defaultListID = lists.contains(where: { $0.id == defaultID }) ? defaultID : nil
  let fetched =
    calendars.isEmpty
    ? [] : try await fetchReminders(store, matching: store.predicateForReminders(in: calendars))
  try requireAccess()
  return try autoreleasepool {
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
      reminders.append(try ReminderRecord(item, now: now, flagged: nil))
    }
    return Inventory(lists: lists, reminders: reminders, defaultListId: defaultListID)
  }
}

// The main run loop drains the main dispatch queue, which drives the main actor.
func remindersRunMainLoop() {
  guard Thread.isMainThread else { return }
  _ = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
  RunLoop.main.run()
}
