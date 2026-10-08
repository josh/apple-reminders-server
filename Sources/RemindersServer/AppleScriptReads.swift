import Foundation

// Fixed read-only source; request values are never interpolated. AppleScript's
// timeout applies to each event, not to app launch or the complete operation.
private let flagsScript = """
  with timeout of 10 seconds
      tell application id "com.apple.reminders"
          set idsBefore to id of every reminder
          set flagValues to flagged of every reminder
          set idsAfter to id of every reminder
          return {idsBefore, flagValues, idsAfter}
      end tell
  end timeout
  """

func readScriptFlagsOnMainThread() throws -> [String: Bool] {
  guard Thread.isMainThread else { throw RemindersError("AppleScript requires the main thread") }
  guard let script = NSAppleScript(source: flagsScript) else {
    throw RemindersError("AppleScript could not be compiled")
  }
  var error: NSDictionary?
  let result = script.executeAndReturnError(&error)
  if let error {
    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
    throw RemindersError(
      "AppleScript Reminders read failed (code \(code)); check Automation permission and Reminders availability"
    )
  }
  guard result.descriptorType == 0x6c69_7374, result.numberOfItems == 3,
    let before = result.atIndex(1), let flags = result.atIndex(2), let after = result.atIndex(3),
    [before, flags, after].allSatisfy({ $0.descriptorType == 0x6c69_7374 }),
    before.numberOfItems == flags.numberOfItems, before.numberOfItems == after.numberOfItems
  else {
    throw RemindersError("AppleScript returned an inconsistent flag inventory")
  }
  var output: [String: Bool] = [:]
  for index in 0..<before.numberOfItems {
    guard let id = before.atIndex(index + 1)?.stringValue,
      id == after.atIndex(index + 1)?.stringValue,
      let flag = flags.atIndex(index + 1),
      [0x626f_6f6c, 0x7472_7565, 0x6661_6c73].contains(flag.descriptorType)
    else {  // typeBoolean ('bool')
      throw RemindersError("AppleScript flag inventory changed or contained an invalid value")
    }
    // Observed macOS mapping: x-apple-reminder://UUID -> EventKit UUID.
    // Accept an exact EventKit UUID as well, but never names or arbitrary URLs.
    let uuid: UUID?
    if let exact = UUID(uuidString: id) {
      uuid = exact
    } else if let url = URL(string: id), url.scheme == "x-apple-reminder", url.path.isEmpty,
      url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil
    {
      uuid = UUID(uuidString: url.host ?? "")
    } else {
      uuid = nil
    }
    guard let key = uuid?.uuidString, output[key] == nil else {
      throw RemindersError("AppleScript reminder ID is unsupported or duplicated")
    }
    output[key] = flag.booleanValue
  }
  return output
}

// Each property is a separate, lazy read: selecting an icon never fetches flags
// or dates. Scripts are fixed by this switch and never include client input.
func readScriptProperty(_ command: String) throws -> [String: Any] {
  let entity: String
  let expression: String
  switch command {
  case "script-emblems":
    entity = "list"
    expression = "emblem of every list"
  case "script-alerts":
    entity = "reminder"
    expression = "remind me date of every reminder"
  case "script-list-containers":
    entity = "list"
    expression = "container of every list"
  case "script-reminder-containers":
    entity = "reminder"
    expression = "container of every reminder"
  default: throw RemindersError("Unknown automation property")
  }
  let source = """
    with timeout of 10 seconds
        tell application id "com.apple.reminders"
            set idsBefore to id of every \(entity)
            set rows to \(expression)
            set idsAfter to id of every \(entity)
            return {idsBefore, rows, idsAfter}
        end tell
    end timeout
    """
  guard Thread.isMainThread, let script = NSAppleScript(source: source) else {
    throw RemindersError("Cannot compile automation property read")
  }
  var error: NSDictionary?
  let result = script.executeAndReturnError(&error)
  if let error {
    throw RemindersError(
      "Reminders automation property read failed (code \(error[NSAppleScript.errorNumber] as? Int ?? 0))"
    )
  }
  guard let before = result.atIndex(1), let rows = result.atIndex(2), let after = result.atIndex(3),
    result.numberOfItems == 3,
    [before, rows, after].allSatisfy({ $0.descriptorType == 0x6c69_7374 }),
    before.numberOfItems == rows.numberOfItems, after.numberOfItems == rows.numberOfItems
  else { throw RemindersError("Inconsistent automation inventory") }
  var output: [String: Any] = [:]
  for index in 0..<rows.numberOfItems {
    guard let value = rows.atIndex(index + 1),
      let id = before.atIndex(index + 1)?.stringValue,
      id == after.atIndex(index + 1)?.stringValue
    else { throw RemindersError("Automation inventory changed during read; retry") }
    let key = try scriptIdentifier(id, kind: entity == "list" ? "ReminderList" : "Reminder")
    guard output[key] == nil else { throw RemindersError("Duplicate automation identifier") }
    if command == "script-emblems" {
      if value.typeCodeValue == 0x6d73_6e67 {
        output[key] = NSNull()
      } else if let text = value.stringValue {
        output[key] = text
      } else {
        throw RemindersError("Unsupported list emblem value")
      }
    } else if command == "script-alerts" {
      if value.typeCodeValue == 0x6d73_6e67 {
        output[key] = NSNull()
      } else if let date = value.dateValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        output[key] = formatter.string(from: date)
      } else {
        throw RemindersError("Unsupported reminder alert date")
      }
    } else {
      guard value.descriptorType == 0x6f62_6a20,
        value.forKeyword(0x666f_726d)?.enumCodeValue == 0x4944_2020,
        let parentID = value.forKeyword(0x7365_6c64)?.stringValue
      else { throw RemindersError("Unsupported container reference") }
      let kinds: [UInt32: String] = [
        0x6163_6374: "Account", 0x6c69_7374: "ReminderList", 0x7265_6d69: "Reminder",
      ]
      guard let kind = kinds[value.forKeyword(0x7761_6e74)?.typeCodeValue ?? 0],
        (entity == "list" ? ["Account", "ReminderList"] : ["ReminderList", "Reminder"]).contains(
          kind)
      else { throw RemindersError("Unsupported container class") }
      output[key] = ["kind": kind, "id": try scriptIdentifier(parentID, kind: kind)]
    }
  }
  return output
}

private func scriptIdentifier(_ value: String, kind: String) throws -> String {
  if let uuid = UUID(uuidString: value) { return uuid.uuidString }
  let prefix: String
  switch kind {
  case "Reminder": prefix = "x-apple-reminder://"
  case "ReminderList": prefix = "x-apple-reminderkit://REMCDList/"
  case "Account": prefix = "x-apple-reminderkit://REMCDAccount/"
  default: throw RemindersError("Unknown automation identifier kind")
  }
  guard value.hasPrefix(prefix), let uuid = UUID(uuidString: String(value.dropFirst(prefix.count)))
  else { throw RemindersError("Unsupported automation identifier format for \(kind)") }
  return uuid.uuidString
}
