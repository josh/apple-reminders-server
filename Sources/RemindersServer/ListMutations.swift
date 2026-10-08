import CoreGraphics
import EventKit
import Foundation

struct ListChanges: Sendable {
  var name: String?
  var color: [Double]?
  var emblem: String?
  init() {}
}
enum ListMutation: Sendable {
  case create(accountID: String, changes: ListChanges)
  case update(id: String, changes: ListChanges)
  case delete(id: String, allowNonEmpty: Bool)
}

func remindersMutateList(_ request: ListMutation) throws -> Data {
  try performRemindersOperation {
    try requireAccess()
    let store = EKEventStore()
    let list: EKCalendar
    let changes: ListChanges?
    switch request {
    case .create(let accountID, let patch):
      guard let source = store.sources.first(where: { $0.sourceIdentifier == accountID }) else {
        throw RemindersError("NOT_FOUND: account is unavailable")
      }
      guard let name = patch.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw RemindersError("INVALID_ARGUMENT: list name must not be blank") }
      list = EKCalendar(for: .reminder, eventStore: store)
      list.source = source
      changes = patch
    case .update(let id, let patch):
      guard let existing = store.calendar(withIdentifier: id),
        existing.allowedEntityTypes.contains(.reminder)
      else { throw RemindersError("NOT_FOUND: reminder list is unavailable") }
      guard !existing.isImmutable && existing.allowsContentModifications && !existing.isSubscribed
      else { throw RemindersError("READ_ONLY: list is not editable") }
      list = existing
      changes = patch
    case .delete(let id, let allowNonEmpty):
      guard let existing = store.calendar(withIdentifier: id),
        existing.allowedEntityTypes.contains(.reminder)
      else { throw RemindersError("NOT_FOUND: reminder list is unavailable") }
      guard !existing.isImmutable && existing.allowsContentModifications && !existing.isSubscribed
      else { throw RemindersError("READ_ONLY: list is not editable") }
      if !allowNonEmpty {
        let pending = Pending<Result<[EKReminder], Error>>()
        let handle = store.fetchReminders(matching: store.predicateForReminders(in: [existing])) {
          items in
          pending.resolve(
            items.map { .success($0) }
              ?? .failure(RemindersError("Cannot determine whether list is empty")))
        }
        let items: [EKReminder]
        do { items = try pending.wait().get() } catch {
          store.cancelFetchRequest(handle)
          throw error
        }
        guard items.isEmpty else {
          throw RemindersError(
            "LIST_NOT_EMPTY: pass allowNonEmpty only to intentionally delete the list and its reminders"
          )
        }
      }
      do { try store.removeCalendar(existing, commit: true) } catch {
        throw RemindersError(
          "WRITE_FAILED: EventKit list deletion failed (code \((error as NSError).code)); refetch before retrying"
        )
      }
      return try JSONSerialization.data(withJSONObject: ["deletedId": id], options: [.sortedKeys])
    }
    guard let patch = changes else { throw RemindersError("Missing list changes") }
    if let name = patch.name {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw RemindersError("INVALID_ARGUMENT: list name must not be blank")
      }
      list.title = name
    }
    if let color = patch.color {
      guard color.count == 4, color[3] == 1,
        color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
        let calendarColor = CGColor(
          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: color.map { CGFloat($0) })
      else { throw RemindersError("INVALID_ARGUMENT: invalid list color") }
      list.cgColor = calendarColor
    }
    let script = patch.emblem != nil ? try makeListEmblemScript() : nil
    do { try store.saveCalendar(list, commit: true) } catch {
      throw RemindersError(
        "WRITE_FAILED: EventKit list save failed (code \((error as NSError).code)); refetch before retrying"
      )
    }
    let id = list.calendarIdentifier
    if let script, let emblem = patch.emblem {
      do { try writeListEmblem(script, id: id, emblem: emblem) } catch {
        throw RemindersError(
          "WRITE_APPLIED: list \(id) was saved, but its emblem write failed: \(error). Refetch this ID before retrying; no rollback was attempted"
        )
      }
    }
    store.reset()
    guard let refreshed = store.calendar(withIdentifier: id) else {
      throw RemindersError("WRITE_APPLIED: list \(id) was saved but is unavailable for refetch")
    }
    return try JSONSerialization.data(withJSONObject: listJSON(refreshed), options: [.sortedKeys])
  }
}

private func makeListEmblemScript() throws -> NSAppleScript {
  let source = """
    on setemblem(listID, iconName)
        with timeout of 10 seconds
            tell application id "com.apple.reminders"
                repeat with attempt from 1 to 30
                    try
                        set targetList to list id listID
                        set emblem of targetList to iconName
                        return {id of targetList, emblem of targetList}
                    on error errorText number errorCode
                        if errorCode is not -1728 and errorCode is not -10006 then error errorText number errorCode
                        if attempt is 30 then error errorText number errorCode
                        delay 1
                    end try
                end repeat
            end tell
        end timeout
    end setemblem
    """
  guard let script = NSAppleScript(source: source) else {
    throw RemindersError("Cannot create list emblem writer")
  }
  var error: NSDictionary?
  guard script.compileAndReturnError(&error) else {
    throw RemindersError("Cannot compile list emblem writer")
  }
  return script
}
private func writeListEmblem(_ script: NSAppleScript, id: String, emblem: String) throws {
  guard let uuid = UUID(uuidString: id) else {
    throw RemindersError("Unsupported list identifier for automation")
  }
  let arguments = NSAppleEventDescriptor.list()
  arguments.insert(.init(string: uuid.uuidString), at: 1)
  arguments.insert(.init(string: emblem), at: 2)
  let event = NSAppleEventDescriptor(
    eventClass: 0x6173_6372, eventID: 0x7073_6272, targetDescriptor: nil, returnID: -1,
    transactionID: 0)
  event.setParam(.init(string: "setemblem"), forKeyword: 0x736e_616d)
  event.setParam(arguments, forKeyword: 0x2d2d_2d2d)
  var error: NSDictionary?
  let result = script.executeAppleEvent(event, error: &error)
  if let error {
    throw RemindersError(
      "Reminders emblem write failed (code \(error[NSAppleScript.errorNumber] as? Int ?? 0))")
  }
  guard result.numberOfItems == 2, result.atIndex(1)?.stringValue == uuid.uuidString,
    result.atIndex(2)?.stringValue == emblem
  else { throw RemindersError("Reminders did not retain the requested emblem") }
}
