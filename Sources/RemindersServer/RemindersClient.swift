import Foundation

// Framework calls run as one main-actor job; the pool releases their temporaries.
// Only Sendable records come back.
private func onMainActor<T: Sendable>(_ body: @MainActor () throws -> T) async throws -> T {
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

func readProperty<Value: Sendable>(_ property: ScriptProperty<Value>) async throws -> [String:
  Value]
{
  try await onMainActor {
    try requireAccess()
    return try readScriptProperty(property)
  }
}
func mutateReminder(_ request: ReminderMutation) async throws -> MutationResult<ReminderRecord> {
  switch try await onMainActor({ try executeMutation(request) }) {
  case .finished(let result): return result
  case .automation(let pending):
    do {
      return .saved(try await untilSynchronized { try applyReminderAutomation(pending) })
    } catch {
      throw writeApplied(error, saved: "reminder \(pending.reminderID)")
    }
  }
}
func mutateList(_ request: ListMutation) async throws -> MutationResult<ListRecord> {
  switch try await remindersMutateList(request) {
  case .finished(let result): return result
  case .automation(let pending):
    do {
      return .saved(try await untilSynchronized { try applyListEmblem(pending) })
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
func showRemindersObject(_ id: String, isList: Bool) async throws -> ShownObject {
  try await onMainActor { try remindersShow(id: id, isList: isList) }
}

struct DeletedReminder: Codable, Sendable { let deletedId: String }
enum MutationResult<Record: Encodable & Sendable>: Encodable, Sendable {
  case saved(Record)
  case deleted(DeletedReminder)
  func savedRecord() throws -> Record {
    guard case .saved(let record) = self else {
      throw ServerError.internalError("Expected a saved record")
    }
    return record
  }
  func deletion() throws -> DeletedReminder {
    guard case .deleted(let result) = self else {
      throw ServerError.internalError("Expected a deletion")
    }
    return result
  }
  func encode(to encoder: Encoder) throws {
    switch self {
    case .saved(let record): try record.encode(to: encoder)
    case .deleted(let result): try result.encode(to: encoder)
    }
  }
}
enum ShownObject: Encodable, Sendable {
  case reminder(ReminderRecord)
  case list(ListRecord)
  func encode(to encoder: Encoder) throws {
    switch self {
    case .reminder(let record): try record.encode(to: encoder)
    case .list(let record): try record.encode(to: encoder)
    }
  }
}
