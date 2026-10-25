import CoreGraphics
import EventKit
import Foundation

struct ListChanges: Sendable {
  var name: String?
  var color: [Double]?
  var emblem: String?
}
enum ListWrite: Sendable {
  case create(accountID: String, changes: ListChanges)
  case update(id: String, changes: ListChanges)
  case delete(id: String, allowNonEmpty: Bool)
}

// Emblem changes apply through Reminders automation after the EventKit save.
struct PendingEmblem: Sendable {
  let listID: String
  let emblem: String
}
enum ListWritePhase: Sendable {
  case finished(WriteResult<ListRecord>)
  case automation(PendingEmblem)
}

@MainActor
func executeListWrite(_ request: ListWrite) async throws -> ListWritePhase {
  try requireAccess()
  let store = EKEventStore()
  let list: EKCalendar
  let changes: ListChanges?
  switch request {
  case .create(let accountID, let patch):
    guard let source = store.sources.first(where: { $0.sourceIdentifier == accountID }) else {
      throw ServerError.notFound("account is unavailable")
    }
    guard patch.name != nil else {
      throw ServerError.invalidArgument("list name must not be blank")
    }
    list = EKCalendar(for: .reminder, eventStore: store)
    list.source = source
    changes = patch
  case .update(let id, let patch):
    list = try editableList(store, id: id)
    changes = patch
  case .delete(let id, let allowNonEmpty):
    let existing = try editableList(store, id: id)
    if !allowNonEmpty {
      let items = try await fetchReminders(
        store, matching: store.predicateForReminders(in: [existing]))
      guard store.calendar(withIdentifier: id) != nil,
        items.allSatisfy({ $0.calendar?.calendarIdentifier == id })
      else { throw ServerError.internalError("Reminder list changed during read; retry") }
      guard items.isEmpty else {
        throw ServerError.listNotEmpty(
          "pass allowNonEmpty only to intentionally delete the list and its reminders"
        )
      }
    }
    do { try store.removeCalendar(existing, commit: true) } catch {
      throw ServerError.writeFailed(
        "EventKit list deletion failed (code \((error as NSError).code)); refetch before retrying"
      )
    }
    return .finished(.deleted(DeletedReminder(deletedId: id)))
  }
  guard let patch = changes else { throw ServerError.internalError("Missing list changes") }
  if let name = patch.name {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ServerError.invalidArgument("list name must not be blank")
    }
    list.title = name
  }
  if let color = patch.color {
    guard
      let calendarColor = CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: color.map { CGFloat($0) })
    else { throw ServerError.invalidArgument("invalid list color") }
    list.cgColor = calendarColor
  }
  // Compile before committing: syntax failures must not leave an avoidable partial write.
  if patch.emblem != nil { _ = try makeListEmblemScript() }
  do { try store.saveCalendar(list, commit: true) } catch {
    throw ServerError.writeFailed(
      "EventKit list save failed (code \((error as NSError).code)); refetch before retrying"
    )
  }
  let id = list.calendarIdentifier
  if let emblem = patch.emblem { return .automation(PendingEmblem(listID: id, emblem: emblem)) }
  store.reset()
  guard let refreshed = store.calendar(withIdentifier: id) else {
    throw ServerError.writeApplied("list \(id) was saved but is unavailable for refetch")
  }
  return .finished(.saved(try ListRecord(refreshed)))
}

@MainActor
private func editableList(_ store: EKEventStore, id: String) throws -> EKCalendar {
  guard let list = reminderList(store, id: id) else {
    throw ServerError.notFound("reminder list is unavailable")
  }
  guard !list.isImmutable && list.allowsContentModifications && !list.isSubscribed else {
    throw ServerError.readOnly("list is not editable")
  }
  return list
}

// One emblem attempt on an already-saved list. AutomationNotReady means Reminders
// has not exposed the list yet; every other failure is final.
@MainActor
func applyListEmblem(_ pending: PendingEmblem) throws -> ListRecord {
  try requireAccess()
  let store = EKEventStore()
  guard store.calendar(withIdentifier: pending.listID) != nil else {
    throw ServerError.internalError("list was removed before its emblem could apply")
  }
  try writeListEmblem(try makeListEmblemScript(), id: pending.listID, emblem: pending.emblem)
  store.reset()
  guard let refreshed = store.calendar(withIdentifier: pending.listID) else {
    throw ServerError.internalError("saved list is not available for refetch")
  }
  return try ListRecord(refreshed)
}

// One attempt per call: untilSynchronized retries between awaits. The short event
// timeout bounds how long one attempt holds the main actor.
@MainActor
private func makeListEmblemScript() throws -> NSAppleScript {
  let source = """
    on setemblem(listID, iconName)
        with timeout of 3 seconds
            tell application id "com.apple.reminders"
                set targetList to list id listID
                set emblem of targetList to iconName
                return {id of targetList, emblem of targetList}
            end tell
        end timeout
    end setemblem
    """
  return try compiledScript(source, what: "list emblem writer")
}
@MainActor
private func writeListEmblem(_ script: NSAppleScript, id: String, emblem: String) throws {
  guard let uuid = UUID(uuidString: id) else {
    throw ServerError.internalError("Unsupported list identifier for automation")
  }
  let result = try callHandler(
    script, "setemblem", [.init(string: uuid.uuidString), .init(string: emblem)])
  guard result.numberOfItems == 2, result.atIndex(1)?.stringValue == uuid.uuidString,
    result.atIndex(2)?.stringValue == emblem
  else { throw ServerError.internalError("Reminders did not retain the requested emblem") }
}
