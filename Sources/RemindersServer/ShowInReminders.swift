import EventKit
import Foundation

/// UI navigation is deliberately separate from data mutations: it performs no save.
@MainActor
func remindersShow(id: String, isList: Bool) throws -> ShownObject {
  try requireAccess()
  let store = EKEventStore()
  let record: ShownObject
  let scriptID: String
  guard let uuid = UUID(uuidString: id) else {
    throw ServerError.invalidArgument("show requires a UUID identifier")
  }
  if isList {
    guard let list = store.calendar(withIdentifier: id),
      list.allowedEntityTypes.contains(.reminder)
    else { throw ServerError.notFound("list is unavailable") }
    record = .list(try ListRecord(list))
    scriptID = uuid.uuidString
  } else {
    guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
      throw ServerError.notFound("reminder is unavailable")
    }
    record = .reminder(try ReminderRecord(item, now: Date(), flagged: nil))
    scriptID = "x-apple-reminder://" + uuid.uuidString
  }
  let script = try makeShowScript()
  let result: NSAppleEventDescriptor
  do {
    result = try callHandler(script, "showitem", [.init(string: scriptID), .init(boolean: isList)])
  } catch {
    throw ServerError.showFailed(
      "Reminders navigation failed (\(error)); the UI may already have changed")
  }
  guard result.stringValue == scriptID else {
    throw ServerError.showFailed(
      "unexpected navigation result; the UI may already have changed")
  }
  return record
}

@MainActor
private func makeShowScript() throws -> NSAppleScript {
  let source = """
    on showitem(objectID, isList)
        with timeout of 10 seconds
            tell application id "com.apple.reminders"
                if isList then
                    set targetObject to list id objectID
                else
                    set targetObject to reminder id objectID
                end if
                show targetObject
                return id of targetObject
            end tell
        end timeout
    end showitem
    """
  return try compiledScript(source, what: "navigation script")
}
