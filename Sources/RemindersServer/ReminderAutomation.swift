import Foundation

// Fixed handler with typed Apple-event arguments. No client text becomes source.
// Match both reminder and containing list IDs before sending any set event.
func makeReminderWriteScript() throws -> NSAppleScript {
  let source = """
    on applychanges(reminderID, listID, changeFlag, flagValue, changeAlert, alertValue)
        with timeout of 10 seconds
            tell application id "com.apple.reminders"
                -- Retry only transient visibility/set failures on this same ID, never creation.
                repeat with attempt from 1 to 30
                    try
                        set targetList to list id listID
                        set matches to every reminder of targetList whose id is reminderID
                        if (count of matches) > 1 then error "Reminder identity is ambiguous"
                        if (count of matches) is 1 then
                            set targetReminder to item 1 of matches
                            if changeFlag then set flagged of targetReminder to flagValue
                            if changeAlert then set remind me date of targetReminder to alertValue
                            return {id of targetReminder, flagged of targetReminder, remind me date of targetReminder}
                        end if
                    on error errorText number errorCode
                        if errorCode is not -10006 and errorCode is not -1728 then error errorText number errorCode
                        if attempt is 30 then error errorText number errorCode
                    end try
                    delay 0.1
                end repeat
                error "Reminder did not become available to automation"
            end tell
        end timeout
    end applychanges
    """
  guard Thread.isMainThread, let script = NSAppleScript(source: source) else {
    throw ServerError.message("Cannot create reminder automation writer")
  }
  var error: NSDictionary?
  guard script.compileAndReturnError(&error) else {
    throw ServerError.message(
      "WRITE_FAILED: cannot compile reminder automation (code \(error?[NSAppleScript.errorNumber] as? Int ?? 0))"
    )
  }
  return script
}

func writeReminderAutomation(
  _ script: NSAppleScript, id: String, listID: String, flagged: Bool?, alert: Date?
) throws {
  guard Thread.isMainThread, let reminderUUID = UUID(uuidString: id),
    let listUUID = UUID(uuidString: listID)
  else {
    throw ServerError.message(
      "UNSUPPORTED_OPERATION: automation requires UUID reminder and list identifiers")
  }
  let reminderID = "x-apple-reminder://" + reminderUUID.uuidString
  let listID = listUUID.uuidString
  let arguments = NSAppleEventDescriptor.list()
  let values: [NSAppleEventDescriptor] = [
    .init(string: reminderID), .init(string: listID), .init(boolean: flagged != nil),
    .init(boolean: flagged ?? false), .init(boolean: alert != nil),
    .init(date: alert ?? Date(timeIntervalSince1970: 0)),
  ]
  for (index, value) in values.enumerated() { arguments.insert(value, at: index + 1) }
  let event = NSAppleEventDescriptor(
    eventClass: 0x6173_6372, eventID: 0x7073_6272, targetDescriptor: nil, returnID: -1,
    transactionID: 0)
  event.setParam(.init(string: "applychanges"), forKeyword: 0x736e_616d)
  event.setParam(arguments, forKeyword: 0x2d2d_2d2d)
  var error: NSDictionary?
  let result = script.executeAppleEvent(event, error: &error)
  if let error {
    throw ServerError.message(
      "Reminders automation write failed (code \(error[NSAppleScript.errorNumber] as? Int ?? 0)): \(error[NSAppleScript.errorMessage] as? String ?? "unknown")"
    )
  }
  guard result.numberOfItems == 3, result.atIndex(1)?.stringValue == reminderID else {
    throw ServerError.message("Automation write returned an inconsistent identity")
  }
  if let flagged {
    guard let value = result.atIndex(2),
      [0x626f_6f6c, 0x7472_7565, 0x6661_6c73].contains(value.descriptorType),
      value.booleanValue == flagged
    else { throw ServerError.message("Reminders did not retain the requested flag") }
  }
  if let alert {
    guard let actual = result.atIndex(3)?.dateValue, abs(actual.timeIntervalSince(alert)) < 1 else {
      throw ServerError.message("Reminders did not retain the requested alert date")
    }
  }
}
