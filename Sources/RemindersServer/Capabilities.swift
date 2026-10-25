import Foundation

struct Capabilities {
  enum Access: Comparable {
    case denied, read, write
  }

  var graphql: Access = .denied
  var mcp: Access = .denied
  var metrics: Access = .denied

  static func parse(header: String?, capability: String?, proxied: Bool) throws -> Capabilities {
    guard let capability else {
      return Capabilities(graphql: .write, mcp: .write, metrics: .read)
    }
    guard let header else {
      guard !proxied else { throw ServerError.forbidden("Forbidden") }
      return Capabilities(graphql: .write, mcp: .write, metrics: .read)
    }
    guard header.utf8.count <= 16_384,
      let grants = try? grantDecoder(capability).decode(Grants.self, from: decodeHeader(header))
    else { throw ServerError.forbidden("Forbidden") }

    var result = Capabilities()
    for grant in grants.grants {
      for (api, level) in grant {
        let access: Access = level == .rw ? .write : .read
        switch api {
        case .graphql: result.graphql = max(result.graphql, access)
        case .mcp: result.mcp = max(result.mcp, access)
        case .metrics:
          guard access == .read else { throw ServerError.forbidden("Forbidden") }
          result.metrics = .read
        }
      }
    }
    return result
  }

  // The capability's grants: a list of objects mapping API names to "r" or "rw".
  // Unknown API names or levels fail decoding, which denies the request.
  private enum API: String, Decodable, CodingKeyRepresentable { case graphql, mcp, metrics }
  private enum Level: String, Decodable { case r, rw }
  private struct Grants: Decodable {
    static let capability = CodingUserInfoKey(rawValue: "capability")!
    struct Key: CodingKey {
      let stringValue: String
      var intValue: Int? { nil }
      init(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }
    let grants: [[API: Level]]
    init(from decoder: Decoder) throws {
      let name = decoder.userInfo[Self.capability] as? String ?? ""
      grants = try decoder.container(keyedBy: Key.self).decode(
        [[API: Level]].self, forKey: Key(stringValue: name))
    }
  }
  private static func grantDecoder(_ capability: String) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.userInfo[Grants.capability] = capability
    return decoder
  }

  // An unknown path is allowed through so the server can answer 404.
  func access(_ route: Route?) -> Access {
    switch route {
    case .graphql: return graphql
    case .mcp: return mcp
    case .metrics: return metrics
    case nil: return .write
    }
  }
  func allows(_ route: Route?) -> Bool { access(route) != .denied }

  // Serve uses RFC2047 UTF-8 Q encoding for non-ASCII capability values.
  // Adjacent encoded words may be separated by whitespace.
  private static func decodeHeader(_ header: String) throws -> Data {
    guard header.hasPrefix("=?") else { return Data(header.utf8) }
    var decoded = Data()
    for word in header.split(whereSeparator: { $0.isWhitespace }) {
      guard word.lowercased().hasPrefix("=?utf-8?q?"), word.hasSuffix("?=") else {
        throw ServerError.forbidden("Forbidden")
      }
      let bytes = Array(word.dropFirst(10).dropLast(2).utf8)
      var index = 0
      while index < bytes.count {
        switch bytes[index] {
        case 61:
          guard index + 2 < bytes.count,
            bytes[(index + 1)...(index + 2)].allSatisfy({
              (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }),
            let byte = UInt8(
              String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16)
          else { throw ServerError.forbidden("Forbidden") }
          decoded.append(byte)
          index += 3
        case 95:
          decoded.append(32)
          index += 1
        default:
          guard (33...126).contains(bytes[index]), bytes[index] != 63 else {
            throw ServerError.forbidden("Forbidden")
          }
          decoded.append(bytes[index])
          index += 1
        }
      }
    }
    guard String(data: decoded, encoding: .utf8) != nil else {
      throw ServerError.forbidden("Forbidden")
    }
    return decoded
  }
}
