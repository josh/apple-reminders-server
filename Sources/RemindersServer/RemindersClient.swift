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
func mutateReminder(_ request: ReminderMutation) async throws -> MutationResult<ReminderRecord> {
  try await withReminders { try executeMutation(request) }
}
func mutateList(_ request: ListMutation) async throws -> MutationResult<ListRecord> {
  try await withReminders { try remindersMutateList(request) }
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
