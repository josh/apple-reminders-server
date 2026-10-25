import Foundation

// One field of decoded API input: absent, explicitly null, or present.
enum InputField<Value: Decodable & Sendable>: Sendable {
  case absent, null
  case present(Value)

  var value: Value? {
    if case .present(let value) = self { return value }
    return nil
  }
  var isAbsent: Bool {
    if case .absent = self { return true }
    return false
  }
  func required(_ name: String) throws -> Value {
    guard let value else { throw ServerError.invalidArgument("\(name) is required") }
    return value
  }
}

extension KeyedDecodingContainer {
  func field<T: Decodable & Sendable>(_ key: Key) throws -> InputField<T> {
    guard contains(key) else { return .absent }
    return try decodeNil(forKey: key) ? .null : .present(decode(T.self, forKey: key))
  }
  func containsNull() throws -> Bool { try allKeys.contains { try decodeNil(forKey: $0) } }
}

private struct AnyKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

extension Decoder {
  // A keyed container that rejects keys the input type does not declare.
  func inputContainer<Key: CodingKey & CaseIterable>(keyedBy: Key.Type) throws
    -> KeyedDecodingContainer<Key>
  {
    let known = Set(Key.allCases.map(\.stringValue))
    guard try container(keyedBy: AnyKey.self).allKeys.allSatisfy({ known.contains($0.stringValue) })
    else { throw ServerError.invalidArgument("Unknown input field") }
    return try container(keyedBy: Key.self)
  }
}

// Decodes GraphQL arguments or MCP tool arguments into a typed input.
func decodeInput<T: Decodable>(_ type: T.Type, from value: some Encodable) throws -> T {
  do {
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  } catch let error as DecodingError {
    throw ServerError.invalidArgument(inputMessage(error))
  }
}

private func inputMessage(_ error: DecodingError) -> String {
  func name(_ path: [CodingKey]) -> String {
    path.isEmpty
      ? "input" : path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
  }
  switch error {
  case .typeMismatch(let type, let context):
    let kind: String
    switch type {
    case is String.Type: kind = "a string"
    case is Int.Type: kind = "an integer"
    case is Double.Type: kind = "a number"
    case is Bool.Type: kind = "a boolean"
    case is [Any].Type: kind = "an array"
    default: kind = "an object"
    }
    return "\(name(context.codingPath)) must be \(kind)"
  case .valueNotFound(_, let context): return "\(name(context.codingPath)) must not be null"
  case .keyNotFound(let key, let context): return "\(name(context.codingPath + [key])) is required"
  case .dataCorrupted(let context): return "\(name(context.codingPath)) is invalid"
  @unknown default: return "invalid input"
  }
}
