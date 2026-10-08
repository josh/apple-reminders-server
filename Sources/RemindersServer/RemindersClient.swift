import Foundation

struct Authorization: Decodable, Sendable { let authorization: String }
// Backend calls block while EventKit and AppleScript work is scheduled on main. Keep
// these calls serialized on a worker queue, never a NIO event loop.
private let remindersQueue = DispatchQueue(label: "reminders.store")
func readRemindersData<T: Decodable & Sendable>(_ command: String) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    remindersQueue.async {
      continuation.resume(
        with: Result {
          try JSONDecoder().decode(T.self, from: remindersRead(command))
        })
    }
  }
}
func readLists() async throws -> ListsSnapshot { try await readRemindersData("lists") }
func readInventory(includeFlags: Bool = false) async throws -> Inventory {
  try await readRemindersData(includeFlags ? "snapshot" : "snapshot_plain")
}
func readReminders(includeFlags: Bool = true) async throws -> [ReminderRecord] {
  let result: RemindersSnapshot = try await readRemindersData(
    includeFlags ? "reminders" : "reminders-base")
  return result.reminders
}

func mutateReminder<T: Decodable & Sendable>(_ request: ReminderMutation) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    remindersQueue.async {
      continuation.resume(
        with: Result { try JSONDecoder().decode(T.self, from: remindersMutate(request)) })
    }
  }
}
struct DeletedReminder: Codable, Sendable { let deletedId: String }

func showRemindersObject<T: Decodable & Sendable>(_ id: String, isList: Bool) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    remindersQueue.async {
      continuation.resume(
        with: Result {
          try JSONDecoder().decode(T.self, from: remindersShow(id: id, isList: isList))
        })
    }
  }
}

func mutateList<T: Decodable & Sendable>(_ request: ListMutation) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    remindersQueue.async {
      continuation.resume(
        with: Result { try JSONDecoder().decode(T.self, from: remindersMutateList(request)) })
    }
  }
}
