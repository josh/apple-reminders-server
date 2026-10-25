import Foundation

/// UI navigation is deliberately separate from data writes: it performs no save.
@MainActor
func showReminderInReminders(id: String) throws -> ReminderRecord {
  let uuid = try showUUID(id)
  guard let item = try readReminder(id: id) else {
    throw ServerError.notFound("reminder is unavailable")
  }
  try navigate(to: "x-apple-reminder://" + uuid.uuidString, isList: false)
  return item
}

@MainActor
func showListInReminders(id: String) throws -> ListRecord {
  let uuid = try showUUID(id)
  guard let list = try readList(id: id) else {
    throw ServerError.notFound("list is unavailable")
  }
  try navigate(to: uuid.uuidString, isList: true)
  return list
}

private func showUUID(_ id: String) throws -> UUID {
  guard let uuid = UUID(uuidString: id) else {
    throw ServerError.invalidArgument("show requires a UUID identifier")
  }
  return uuid
}

@MainActor
private func navigate(to scriptID: String, isList: Bool) throws {
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
