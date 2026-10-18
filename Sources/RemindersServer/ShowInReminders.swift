import EventKit
import Foundation

/// UI navigation is deliberately separate from data mutations: it performs no save.
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
    record = .list(ListRecord(list))
    scriptID = uuid.uuidString
  } else {
    guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
      throw ServerError.notFound("reminder is unavailable")
    }
    record = .reminder(try ReminderRecord(item, now: Date(), flagged: nil))
    scriptID = "x-apple-reminder://" + uuid.uuidString
  }
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
  guard let script = NSAppleScript(source: source) else {
    throw ServerError.internalError("Cannot create navigation script")
  }
  let arguments = NSAppleEventDescriptor.list()
  arguments.insert(.init(string: scriptID), at: 1)
  arguments.insert(.init(boolean: isList), at: 2)
  let event = NSAppleEventDescriptor(
    eventClass: 0x6173_6372, eventID: 0x7073_6272, targetDescriptor: nil, returnID: -1,
    transactionID: 0)
  event.setParam(.init(string: "showitem"), forKeyword: 0x736e_616d)
  event.setParam(arguments, forKeyword: 0x2d2d_2d2d)
  var error: NSDictionary?
  let result = script.executeAppleEvent(event, error: &error)
  if let error {
    throw ServerError.showFailed(
      "Reminders navigation failed (code \(error[NSAppleScript.errorNumber] as? Int ?? 0)); the UI may already have changed"
    )
  }
  guard result.stringValue == scriptID else {
    throw ServerError.showFailed(
      "unexpected navigation result; the UI may already have changed")
  }
  return record
}
