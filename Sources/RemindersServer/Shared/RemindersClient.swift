import Foundation

// Framework calls run as one main-actor job; the pool releases their temporaries.
// Only Sendable records come back.
func onMainActor<T: Sendable>(_ body: @MainActor () throws -> T) async throws -> T {
  try await MainActor.run { try autoreleasepool(invoking: body) }
}

// Reminders exposes saved objects to scripting late. Awaiting the sleep releases
// the main actor, so other requests run between attempts.
func untilSynchronized<T: Sendable>(_ attempt: @MainActor () throws -> T) async throws -> T {
  let clock = ContinuousClock()
  let end = clock.now + .seconds(15)
  while true {
    do {
      return try await onMainActor(attempt)
    } catch is AutomationNotReady where clock.now < end {
      try await clock.sleep(for: .milliseconds(500))
    }
  }
}

func writeReminder(_ request: ReminderWrite) async throws -> ReminderRecord {
  switch try await onMainActor({ try executeReminderWrite(request) }) {
  case .finished(let record): return record
  case .automation(let pending):
    do {
      return try await untilSynchronized { try applyReminderAutomation(pending) }
    } catch {
      throw writeApplied(error, saved: "reminder \(pending.reminderID)")
    }
  }
}
func writeList(_ request: ListWrite) async throws -> ListRecord {
  switch try await onMainActor({ try executeListWrite(request) }) {
  case .finished(let record): return record
  case .automation(let pending):
    do {
      return try await untilSynchronized { try applyListEmblem(pending) }
    } catch {
      throw writeApplied(error, saved: "list \(pending.listID)")
    }
  }
}
// The EventKit save succeeded; only the automation step after it failed.
private func writeApplied(_ error: Error, saved object: String) -> ServerError {
  let reason: String
  switch error {
  case let notReady as AutomationNotReady:
    reason =
      "Reminders did not expose it to automation in time (code \(notReady.code): \(notReady.message))"
  case is CancellationError: reason = "the request was cancelled before automation finished"
  default: reason = "automation or refetch failed: \(error)"
  }
  return .writeApplied("EventKit saved \(object), but \(reason). Refetch this ID before retrying")
}
func deleteReminder(id: String) async throws -> DeletedReminder {
  try await onMainActor { try executeReminderDelete(id: id) }
}
func showReminder(id: String) async throws -> ReminderRecord {
  try await onMainActor { try showReminderInReminders(id: id) }
}
func showList(id: String) async throws -> ListRecord {
  try await onMainActor { try showListInReminders(id: id) }
}

struct DeletedReminder: Encodable, Sendable {
  let deletedId: String
  enum CodingKeys: String, CodingKey { case deletedId }
}
