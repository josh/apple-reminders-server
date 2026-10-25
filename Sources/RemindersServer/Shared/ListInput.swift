import Foundation

// List create and patch input. Only creation accepts accountId.
struct ListInput: Decodable, Sendable {
  let accountId, name, color, emblem: InputField<String>
  let containsNull: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case accountId, name, color, emblem
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    accountId = try c.field(.accountId)
    name = try c.field(.name)
    color = try c.field(.color)
    emblem = try c.field(.emblem)
    containsNull = try c.containsNull()
  }
}

func listChanges(_ input: ListInput, creating: Bool) throws -> ListChanges {
  guard creating || input.accountId.isAbsent else {
    throw ServerError.invalidArgument("Unknown input field")
  }
  if !creating && input.containsNull {
    throw ServerError.invalidArgument("list patch values must not be null")
  }
  var result = ListChanges()
  result.name = input.name.value
  result.emblem = input.emblem.value
  if let emblem = result.emblem, emblem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw ServerError.invalidArgument("emblem must not be blank")
  }
  if let color = input.color.value {
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
