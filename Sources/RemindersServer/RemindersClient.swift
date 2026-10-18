import Foundation

// One queue and main-thread guard protect every EventKit/AppleScript operation.
// Framework objects stay on main; only Sendable records cross the continuation.
private let remindersQueue = DispatchQueue(label: "reminders.store")
func withReminders<T: Sendable>(
  _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    remindersQueue.async {
      continuation.resume(with: Result { try performRemindersOperation(operation) })
    }
  }
}

// Reminders exposes saved objects to scripting late. Sleeping here, outside
// withReminders, lets other requests use the store between attempts.
func untilSynchronized<T: Sendable>(
  within deadline: Duration = .seconds(15),
  _ attempt: @escaping @Sendable () throws -> T
) async throws -> T {
  let clock = ContinuousClock()
  let end = clock.now + deadline
  while true {
    do {
      return try await withReminders(attempt)
    } catch is AutomationNotReady where clock.now < end {
      try await clock.sleep(for: .milliseconds(500))
    }
  }
}

func readInventory(includeFlags: Bool = false) async throws -> Inventory {
  try await withReminders { try fetchInventory(includeFlags: includeFlags) }
}
func readReminders() async throws -> [ReminderRecord] {
  try await readInventory(includeFlags: true).reminders
}
func readProperty<Value: Sendable>(_ property: ScriptProperty<Value>) async throws -> [String:
  Value]
{
  try await withReminders {
    try requireAccess()
    return try readScriptProperty(property)
  }
}
func clearCompletedReminders(listID: String) async throws -> ClearCompletedResult {
  try await withReminders { try executeClearCompleted(listID: listID) }
}
func mutateReminder(_ request: ReminderMutation) async throws -> MutationResult<ReminderRecord> {
  switch try await withReminders({ try executeMutation(request) }) {
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
  switch try await withReminders({ try remindersMutateList(request) }) {
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
  switch error {
  case let notReady as AutomationNotReady:
    return .message(
      "WRITE_APPLIED: EventKit saved \(object), but Reminders did not expose it to automation in time (code \(notReady.code): \(notReady.message)). Refetch this ID and reapply the change with an update"
    )
  case is CancellationError:
    return .message(
      "WRITE_APPLIED: EventKit saved \(object), but the request was cancelled before automation finished. Refetch this ID before retrying"
    )
  default:
    return .message(
      "WRITE_APPLIED: EventKit saved \(object), but automation or refetch failed: \(error). Refetch this ID before retrying"
    )
  }
}
func showRemindersObject(_ id: String, isList: Bool) async throws -> ShownObject {
  try await withReminders { try remindersShow(id: id, isList: isList) }
}

struct DeletedReminder: Codable, Sendable { let deletedId: String }
enum MutationResult<Record: Encodable & Sendable>: Encodable, Sendable {
  case saved(Record)
  case deleted(DeletedReminder)
  func savedRecord() throws -> Record {
    guard case .saved(let record) = self else {
      throw ServerError.message("Expected a saved record")
    }
    return record
  }
  func deletion() throws -> DeletedReminder {
    guard case .deleted(let result) = self else { throw ServerError.message("Expected a deletion") }
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
