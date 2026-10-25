import Foundation

func listChanges(_ input: JSONInput, creating: Bool) throws -> ListChanges {
  try input.checkKeys(
    creating ? ["name", "accountId", "color", "emblem"] : ["name", "color", "emblem"])
  let values = try input.dictionaryValue()
  if !creating && values.values.contains(.null) {
    throw ServerError.invalidArgument("list patch values must not be null")
  }
  var result = ListChanges()
  result.name = try input["name"].optionalString()
  result.emblem = try input["emblem"].optionalString()
  if let emblem = result.emblem, emblem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw ServerError.invalidArgument("emblem must not be blank")
  }
  if let color = try input["color"].optionalString() {
    guard color.range(of: #"^#[0-9A-Fa-f]{6}([Ff]{2})?\z"#, options: .regularExpression) != nil
    else {
      throw ServerError.invalidArgument(
        "list colors must be opaque: use #RRGGBB or #RRGGBBFF")
    }
    let rgba = UInt32(color.dropFirst() + (color.count == 7 ? "FF" : ""), radix: 16)!
    result.color = (0..<4).map { Double(rgba >> (24 - 8 * $0) & 0xFF) / 255 }
  }
  guard creating || result.name != nil || result.color != nil || result.emblem != nil else {
    throw ServerError.invalidArgument("list patch must contain at least one change")
  }
  return result
}
