import CoreGraphics
import EventKit
import Foundation

// EventKit and AppleScript run on the main actor. EventKit calls back on an
// arbitrary queue, and cancelling a fetch suppresses its callback, so the stream
// finishes exactly once: on completion, cancellation, or the timeout. Only
// Sendable records leave the main actor.
@MainActor
func fetchReminders(_ store: EKEventStore, matching predicate: NSPredicate) async throws
  -> [EKReminder]
{
  let (stream, continuation) = AsyncThrowingStream<[EKReminder], Error>.makeStream()
  let handle = store.fetchReminders(matching: predicate) { items in
    guard let items else {
      return continuation.finish(
        throwing: ServerError.internalError(
          "EventKit returned an indeterminate nil reminder inventory"))
    }
    continuation.yield(items)
    continuation.finish()
  }
  continuation.onTermination = { _ in
    DispatchQueue.main.async { store.cancelFetchRequest(handle) }
  }
  let timeout = Task {
    try await Task.sleep(for: .seconds(30))
    continuation.finish(
      throwing: ServerError.internalError("EventKit operation timed out after 30 seconds"))
  }
  defer { timeout.cancel() }
  for try await items in stream { return items }
  throw CancellationError()
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
// Resolution follows projectDate: unsupported or non-roundtripping components are
// unknown, not zero.
func dueStatus(_ components: DateComponents?, now: Date) -> DueStatus {
  guard let components else { return .unscheduled }
  guard let resolved = try? projectDate(ComponentDate(components)) else { return .unknown }
  if resolved.timed && resolved.instant < now { return .overdue }
  var reporting = Calendar(identifier: .gregorian)
  reporting.timeZone = .current
  let comparison = reporting.compare(resolved.instant, to: now, toGranularity: .day)
  return comparison == .orderedAscending ? .overdue : comparison == .orderedSame ? .today : .future
}
// Calendar-day searches use the same resolution rules as deadline metrics.
func dueDay(_ components: DateComponents?) -> String? {
  guard let components, let resolved = try? projectDate(ComponentDate(components)) else {
    return nil
  }
  return resolved.instant.formatted(
    Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
}
@MainActor
func authorizeReminders() async throws {
  let granted: Bool
  do { granted = try await EKEventStore().requestFullAccessToReminders() } catch {
    throw ServerError.internalError(
      "EventKit authorization failed (code \((error as NSError).code))")
  }
  guard granted else { throw ServerError.internalError("Reminders access was not granted") }
  try requireAccess()
}

@MainActor
private func readCalendars() throws -> (
  store: EKEventStore, calendars: [EKCalendar], lists: [ListRecord], defaultListID: String?
) {
  try requireAccess()
  let store = EKEventStore()
  let calendars = store.calendars(for: .reminder).sorted {
    $0.calendarIdentifier < $1.calendarIdentifier
  }
  let lists = try calendars.map(ListRecord.init)
  let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
  let defaultListID = lists.contains(where: { $0.id == defaultID }) ? defaultID : nil
  return (store, calendars, lists, defaultListID)
}
// Lists and the default list without fetching reminders; summaries need readInventory.
@MainActor
func readLists() throws -> Inventory {
  let (_, _, lists, defaultListID) = try readCalendars()
  return Inventory(lists: lists, reminders: [], defaultListId: defaultListID)
}
@MainActor
func readInventory() async throws -> Inventory {
  let (store, calendars, lists, defaultListID) = try readCalendars()
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
@MainActor
func readReminder(id: String) throws -> ReminderRecord? {
  try requireAccess()
  return try (EKEventStore().calendarItem(withIdentifier: id) as? EKReminder).map {
    try ReminderRecord($0, now: Date(), flagged: nil)
  }
}
// A reminder list by identifier; nil when absent or not a reminder list.
@MainActor
func reminderList(_ store: EKEventStore, id: String) -> EKCalendar? {
  guard let list = store.calendar(withIdentifier: id), list.allowedEntityTypes.contains(.reminder)
  else { return nil }
  return list
}
@MainActor
func readList(id: String) throws -> ListRecord? {
  try requireAccess()
  return try reminderList(EKEventStore(), id: id).map(ListRecord.init)
}
