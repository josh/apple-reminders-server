import Foundation

func listChanges(_ input: MutationInput, creating: Bool) throws -> ListChanges {
  try input.checkKeys(
    creating ? ["name", "accountId", "color", "emblem"] : ["name", "color", "emblem"])
  let values = try input.dictionaryValue()
  if !creating && values.values.contains(.null) {
    throw ServerError.invalidArgument("list patch values must not be null")
  }
  var result = ListChanges()
  func text(_ key: String) throws -> String? {
    input[key] == .null || input[key] == .undefined ? nil : try input[key].stringValue()
  }
  result.name = try text("name")
  result.emblem = try text("emblem")
  if let name = result.name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw ServerError.invalidArgument("list name must not be blank")
  }
  if let emblem = result.emblem, emblem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw ServerError.invalidArgument("emblem must not be blank")
  }
  if let color = try text("color") {
    guard color.range(of: #"^#[0-9A-Fa-f]{6}([Ff]{2})?\z"#, options: .regularExpression) != nil
    else {
      throw ServerError.invalidArgument(
        "list colors must be opaque: use #RRGGBB or #RRGGBBFF")
    }
    let hex = String(color.dropFirst()) + (color.count == 7 ? "FF" : "")
    result.color = stride(from: 0, to: 8, by: 2).map { index in
      let start = hex.index(hex.startIndex, offsetBy: index)
      return Double(Int(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!) / 255
    }
  }
  guard creating || result.name != nil || result.color != nil || result.emblem != nil else {
    throw ServerError.invalidArgument("list patch must contain at least one change")
  }
  return result
}
