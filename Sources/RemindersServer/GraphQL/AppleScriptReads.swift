import Carbon
import Foundation

// GraphQL reads flags, emblems, alert dates, and containers through Reminders automation.
enum ScriptObjectKind: Sendable {
  case account, list, reminder
  // The class name in Reminders' scripting dictionary.
  var scriptName: String {
    switch self {
    case .account: "account"
    case .list: "list"
    case .reminder: "reminder"
    }
  }
}
struct ContainerReference: Sendable {
  let kind: ScriptObjectKind
  let id: String
}

func readProperty<Value: Sendable>(_ property: ScriptProperty<Value>) async throws -> [String:
  Value]
{
  try await onMainActor {
    try requireAccess()
    return try readScriptProperty(property)
  }
}

// Fixed read-only sources; request values are never interpolated. AppleScript's
// timeout applies to each event, not to app launch or the complete operation.
// Typed descriptors bind each fixed script expression to its result decoder.
struct ScriptProperty<Value: Sendable>: Sendable {
  let entity: ScriptObjectKind
  let expression: String
  let decode: @Sendable (NSAppleEventDescriptor) throws -> Value
}
extension ScriptProperty where Value == Bool {
  static let flags = Self(
    entity: .reminder, expression: "flagged of every reminder", decode: automationFlag)
}
extension ScriptProperty where Value == String? {
  static let emblems = Self(entity: .list, expression: "emblem of every list") { value in
    if value.typeCodeValue == OSType(cMissingValue) { return nil }
    guard let text = value.stringValue else {
      throw ServerError.internalError("Unsupported list emblem value")
    }
    return text
  }
  static let alerts = Self(entity: .reminder, expression: "remind me date of every reminder") {
    value in
    if value.typeCodeValue == OSType(cMissingValue) { return nil }
    guard let date = value.dateValue else {
      throw ServerError.internalError("Unsupported reminder alert date")
    }
    return timestamp(date)
  }
}
extension ScriptProperty where Value == ContainerReference {
  static let listContainers = containers(entity: .list)
  static let reminderContainers = containers(entity: .reminder)
  private static func containers(entity: ScriptObjectKind) -> Self {
    Self(entity: entity, expression: "container of every \(entity.scriptName)") { value in
      guard value.descriptorType == DescType(typeObjectSpecifier),
        value.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formUniqueID),
        let parentID = value.forKeyword(AEKeyword(keyAEKeyData))?.stringValue
      else { throw ServerError.internalError("Unsupported container reference") }
      let kinds: [OSType: ScriptObjectKind] = [
        classCode("acct"): .account, classCode("list"): .list, classCode("remi"): .reminder,
      ]
      guard let kind = kinds[value.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue ?? 0],
        (entity == .list ? [.account, .list] : [.list, .reminder]).contains(kind)
      else { throw ServerError.internalError("Unsupported container class") }
      return ContainerReference(kind: kind, id: try scriptIdentifier(parentID, kind: kind))
    }
  }
}
// A four-character code from Reminders' scripting dictionary, which has no Apple constant.
private func classCode(_ code: String) -> OSType {
  code.utf8.reduce(0) { $0 << 8 | OSType($1) }
}
@MainActor
func readScriptProperty<Value>(_ property: ScriptProperty<Value>) throws -> [String: Value] {
  let entity = property.entity.scriptName
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
    [before, rows, after].allSatisfy({ $0.descriptorType == DescType(typeAEList) }),
    before.numberOfItems == rows.numberOfItems, after.numberOfItems == rows.numberOfItems
  else { throw ServerError.internalError("Inconsistent automation read") }
  var output: [String: Value] = [:]
  for index in 0..<rows.numberOfItems {
    guard let value = rows.atIndex(index + 1),
      let id = before.atIndex(index + 1)?.stringValue,
      id == after.atIndex(index + 1)?.stringValue
    else { throw ServerError.internalError("Automation objects changed during read; retry") }
    let key = try scriptIdentifier(id, kind: property.entity)
    guard output[key] == nil else {
      throw ServerError.internalError("Duplicate automation identifier")
    }
    // updateValue preserves an explicit nil payload when Value is Optional.
    output.updateValue(try property.decode(value), forKey: key)
  }

  return output
}

private func scriptIdentifier(_ value: String, kind: ScriptObjectKind) throws -> String {
  if let uuid = UUID(uuidString: value) { return uuid.uuidString }
  let prefix: String
  switch kind {
  case .reminder: prefix = "x-apple-reminder://"
  case .list: prefix = "x-apple-reminderkit://REMCDList/"
  case .account: prefix = "x-apple-reminderkit://REMCDAccount/"
  }
  guard value.hasPrefix(prefix), let uuid = UUID(uuidString: String(value.dropFirst(prefix.count)))
  else { throw ServerError.internalError("Unsupported automation identifier format for \(kind)") }
  return uuid.uuidString
}
