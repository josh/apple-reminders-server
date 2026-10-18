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

// Emblem changes apply through Reminders automation after the EventKit save.
struct PendingEmblem: Sendable {
  let listID: String
  let emblem: String
}
enum ListMutationPhase: Sendable {
  case finished(MutationResult<ListRecord>)
  case automation(PendingEmblem)
}

func remindersMutateList(_ request: ListMutation) throws -> ListMutationPhase {
  try requireAccess()
  let store = EKEventStore()
  let list: EKCalendar
  let changes: ListChanges?
  switch request {
  case .create(let accountID, let patch):
    guard let source = store.sources.first(where: { $0.sourceIdentifier == accountID }) else {
      throw ServerError.notFound("account is unavailable")
    }
    guard let name = patch.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ServerError.invalidArgument("list name must not be blank") }
    list = EKCalendar(for: .reminder, eventStore: store)
    list.source = source
    changes = patch
  case .update(let id, let patch):
    guard let existing = store.calendar(withIdentifier: id),
      existing.allowedEntityTypes.contains(.reminder)
    else { throw ServerError.notFound("reminder list is unavailable") }
    guard !existing.isImmutable && existing.allowsContentModifications && !existing.isSubscribed
    else { throw ServerError.readOnly("list is not editable") }
    list = existing
    changes = patch
  case .delete(let id, let allowNonEmpty):
    guard let existing = store.calendar(withIdentifier: id),
      existing.allowedEntityTypes.contains(.reminder)
    else { throw ServerError.notFound("reminder list is unavailable") }
    guard !existing.isImmutable && existing.allowsContentModifications && !existing.isSubscribed
    else { throw ServerError.readOnly("list is not editable") }
    if !allowNonEmpty {
      let pending = Pending<Result<[EKReminder], Error>>()
      let handle = store.fetchReminders(matching: store.predicateForReminders(in: [existing])) {
        items in
        pending.resolve(
          items.map { .success($0) }
            ?? .failure(ServerError.internalError("Cannot determine whether list is empty")))
      }
      let items: [EKReminder]
      do { items = try pending.wait().get() } catch {
        store.cancelFetchRequest(handle)
        throw error
      }
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
    guard color.count == 4, color[3] == 1,
      color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
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
  return .finished(.saved(ListRecord(refreshed)))
}

// One emblem attempt on an already-saved list. AutomationNotReady means Reminders
// has not exposed the list yet; every other failure is final.
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
  return ListRecord(refreshed)
}

// One attempt per call: retry timing lives off the main thread in synchronize.
// The short event timeout bounds how long one attempt holds the main thread.
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
  guard let script = NSAppleScript(source: source) else {
    throw ServerError.internalError("Cannot create list emblem writer")
  }
  var error: NSDictionary?
  guard script.compileAndReturnError(&error) else {
    throw ServerError.internalError("Cannot compile list emblem writer")
  }
  return script
}
private func writeListEmblem(_ script: NSAppleScript, id: String, emblem: String) throws {
  guard let uuid = UUID(uuidString: id) else {
    throw ServerError.internalError("Unsupported list identifier for automation")
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
    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
    let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
    if automationNotReadyCodes.contains(code) {
      throw AutomationNotReady(code: code, message: message)
    }
    throw ServerError.internalError("Reminders emblem write failed (code \(code)): \(message)")
  }
  guard result.numberOfItems == 2, result.atIndex(1)?.stringValue == uuid.uuidString,
    result.atIndex(2)?.stringValue == emblem
  else { throw ServerError.internalError("Reminders did not retain the requested emblem") }
}
