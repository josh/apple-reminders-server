import Carbon
import Foundation

// Reminders has not exposed the saved object to scripting yet, refused the set
// transiently, or let the event time out (it hangs lookups of objects it has not
// loaded). Callers retry the automation step only; EventKit saves never repeat.
struct AutomationNotReady: Error, Sendable {
  let code: Int
  let message: String
}
// -1728: object not found; -10006: cannot set; -1712: event timed out, which
// Reminders produces for a reminder or list it has not loaded yet.
let automationNotReadyCodes: Set<Int> = [-1728, -10006, -1712]

// Fixed handlers compiled once per process. No client text becomes source.
@MainActor private var compiledScripts: [String: NSAppleScript] = [:]
@MainActor
func compiledScript(_ source: String, what: String) throws -> NSAppleScript {
  if let script = compiledScripts[source] { return script }
  guard let script = NSAppleScript(source: source) else {
    throw ServerError.internalError("Cannot create \(what)")
  }
  var error: NSDictionary?
  guard script.compileAndReturnError(&error) else {
    throw ServerError.internalError(
      "Cannot compile \(what) (code \(error?[NSAppleScript.errorNumber] as? Int ?? 0))")
  }
  compiledScripts[source] = script
  return script
}
// Calls a handler with typed Apple-event arguments. Not-ready codes surface as
// AutomationNotReady so callers can retry the automation step.
@MainActor
func callHandler(
  _ script: NSAppleScript, _ name: String, _ arguments: [NSAppleEventDescriptor]
) throws -> NSAppleEventDescriptor {
  let list = NSAppleEventDescriptor.list()
  for (index, value) in arguments.enumerated() { list.insert(value, at: index + 1) }
  let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
    targetDescriptor: nil, returnID: -1, transactionID: 0)
  event.setParam(.init(string: name), forKeyword: AEKeyword(keyASSubroutineName))
  event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
  var error: NSDictionary?
  let result = script.executeAppleEvent(event, error: &error)
  if let error {
    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
    let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
    if automationNotReadyCodes.contains(code) {
      throw AutomationNotReady(code: code, message: message)
    }
    throw ServerError.internalError("Reminders handler \(name) failed (code \(code)): \(message)")
  }
  return result
}

// Decodes a reminder's flag from an automation result.
@Sendable func automationFlag(_ value: NSAppleEventDescriptor) throws -> Bool {
  let booleans = [DescType(typeBoolean), DescType(typeTrue), DescType(typeFalse)]
  guard booleans.contains(value.descriptorType) else {
    throw ServerError.internalError("Unsupported reminder flag value")
  }
  return value.booleanValue
}

// Match both reminder and containing list IDs before sending any set event.
// One attempt per call: untilSynchronized retries between awaits. The short event
// timeout bounds how long one attempt holds the main actor.
@MainActor
func makeReminderWriteScript() throws -> NSAppleScript {
  let source = """
    on applychanges(reminderID, listID, changeFlag, flagValue, changeAlert, alertValue)
        with timeout of 3 seconds
            tell application id "com.apple.reminders"
                set targetList to list id listID
                set matches to every reminder of targetList whose id is reminderID
                if (count of matches) > 1 then error "Reminder identity is ambiguous"
                if (count of matches) is 0 then error "Reminder is not yet visible to automation" number -1728
                set targetReminder to item 1 of matches
                if changeFlag then set flagged of targetReminder to flagValue
                if changeAlert then set remind me date of targetReminder to alertValue
                return {id of targetReminder, flagged of targetReminder, remind me date of targetReminder}
            end tell
        end timeout
    end applychanges
    """
  return try compiledScript(source, what: "reminder automation writer")
}

@MainActor
func writeReminderAutomation(
  _ script: NSAppleScript, id: String, listID: String, flagged: Bool?, alert: Date?
) throws {
  guard let reminderUUID = UUID(uuidString: id), let listUUID = UUID(uuidString: listID) else {
    throw ServerError.unsupportedOperation(
      "automation requires UUID reminder and list identifiers")
  }
  let reminderID = "x-apple-reminder://" + reminderUUID.uuidString
  let result = try callHandler(
    script, "applychanges",
    [
      .init(string: reminderID), .init(string: listUUID.uuidString),
      .init(boolean: flagged != nil), .init(boolean: flagged ?? false),
      .init(boolean: alert != nil), .init(date: alert ?? Date(timeIntervalSince1970: 0)),
    ])
  guard result.numberOfItems == 3, result.atIndex(1)?.stringValue == reminderID else {
    throw ServerError.internalError("Automation write returned an inconsistent identity")
  }
  if let flagged {
    guard let value = result.atIndex(2),
      (try? automationFlag(value)) == flagged
    else { throw ServerError.internalError("Reminders did not retain the requested flag") }
  }
  if let alert {
    guard let actual = result.atIndex(3)?.dateValue, abs(actual.timeIntervalSince(alert)) < 1 else {
      throw ServerError.internalError("Reminders did not retain the requested alert date")
    }
  }
}
