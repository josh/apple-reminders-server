import Foundation

// Fixed read-only sources; request values are never interpolated. AppleScript's
// timeout applies to each event, not to app launch or the complete operation.
// Typed descriptors bind each fixed script expression to its result decoder.
struct ScriptProperty<Value: Sendable>: Sendable {
  let entity: String
  let expression: String
  let decode: @Sendable (NSAppleEventDescriptor) throws -> Value
}
extension ScriptProperty where Value == Bool {
  static let flags = Self(entity: "reminder", expression: "flagged of every reminder") { value in
    // typeBoolean, typeTrue, typeFalse
    guard [0x626f_6f6c, 0x7472_7565, 0x6661_6c73].contains(value.descriptorType) else {
      throw ServerError.internalError("Unsupported reminder flag value")
    }
    return value.booleanValue
  }
}
extension ScriptProperty where Value == String? {
  static let emblems = Self(entity: "list", expression: "emblem of every list") { value in
    if value.typeCodeValue == 0x6d73_6e67 { return nil }
    guard let text = value.stringValue else {
      throw ServerError.internalError("Unsupported list emblem value")
    }
    return text
  }
  static let alerts = Self(entity: "reminder", expression: "remind me date of every reminder") {
    value in
    if value.typeCodeValue == 0x6d73_6e67 { return nil }
    guard let date = value.dateValue else {
      throw ServerError.internalError("Unsupported reminder alert date")
    }
    return timestamp(date)
  }
}
extension ScriptProperty where Value == ContainerReference {
  static let listContainers = containers(entity: "list")
  static let reminderContainers = containers(entity: "reminder")
  private static func containers(entity: String) -> Self {
    Self(entity: entity, expression: "container of every \(entity)") { value in
      guard value.descriptorType == 0x6f62_6a20,
        value.forKeyword(0x666f_726d)?.enumCodeValue == 0x4944_2020,
        let parentID = value.forKeyword(0x7365_6c64)?.stringValue
      else { throw ServerError.internalError("Unsupported container reference") }
      let kinds: [UInt32: String] = [
        0x6163_6374: "Account", 0x6c69_7374: "ReminderList", 0x7265_6d69: "Reminder",
      ]
      guard let kind = kinds[value.forKeyword(0x7761_6e74)?.typeCodeValue ?? 0],
        (entity == "list" ? ["Account", "ReminderList"] : ["ReminderList", "Reminder"]).contains(
          kind)
      else { throw ServerError.internalError("Unsupported container class") }
      return ContainerReference(kind: kind, id: try scriptIdentifier(parentID, kind: kind))
    }
  }
}
@MainActor
func readScriptProperty<Value>(_ property: ScriptProperty<Value>) throws -> [String: Value] {
  let entity = property.entity
  let expression = property.expression
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
  let script = try compiledScript(source, what: "automation property read")
  var error: NSDictionary?
  let result = script.executeAndReturnError(&error)
  if let error {
    throw ServerError.internalError(
      "Reminders automation property read failed (code \(error[NSAppleScript.errorNumber] as? Int ?? 0))"
    )
  }
  guard let before = result.atIndex(1), let rows = result.atIndex(2), let after = result.atIndex(3),
    result.numberOfItems == 3,
    [before, rows, after].allSatisfy({ $0.descriptorType == 0x6c69_7374 }),
    before.numberOfItems == rows.numberOfItems, after.numberOfItems == rows.numberOfItems
  else { throw ServerError.internalError("Inconsistent automation inventory") }
  var output: [String: Value] = [:]
  for index in 0..<rows.numberOfItems {
    guard let value = rows.atIndex(index + 1),
      let id = before.atIndex(index + 1)?.stringValue,
      id == after.atIndex(index + 1)?.stringValue
    else { throw ServerError.internalError("Automation inventory changed during read; retry") }
    let key = try scriptIdentifier(id, kind: entity == "list" ? "ReminderList" : "Reminder")
    guard output[key] == nil else {
      throw ServerError.internalError("Duplicate automation identifier")
    }
    // updateValue preserves an explicit nil payload when Value is Optional.
    output.updateValue(try property.decode(value), forKey: key)
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
  default: throw ServerError.internalError("Unknown automation identifier kind")
  }
  guard value.hasPrefix(prefix), let uuid = UUID(uuidString: String(value.dropFirst(prefix.count)))
  else { throw ServerError.internalError("Unsupported automation identifier format for \(kind)") }
  return uuid.uuidString
}
