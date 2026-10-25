import Foundation

struct Capabilities {
  enum Access: Comparable {
    case denied, read, write
  }

  var graphql: Access = .denied
  var mcp: Access = .denied
  var metrics: Access = .denied

  // A Listeners socket: who can connect is limited by the plist, so every API is open.
  static let full = Capabilities(graphql: .write, mcp: .write, metrics: .read)
  // Sockets dedicated to one API.
  static let metricsOnly = Capabilities(metrics: .read)
  static let graphqlOnly = Capabilities(graphql: .write)
  static let mcpOnly = Capabilities(mcp: .write)

  // A TailscaleServe socket: Serve sends the caller's grants for the capability; a
  // request without them gets nothing.
  // Each failure names its reason for the request log; clients only see "Forbidden".
  static func parse(header: String?, capability: String) throws -> Capabilities {
    guard let header else { throw ServerError.forbidden("no capability header") }
    guard header.utf8.count <= 16_384 else {
      throw ServerError.forbidden("capability header exceeds 16 KiB")
    }
    let data = try decodeHeader(header)
    let decoder = JSONDecoder()
    decoder.userInfo[Grants.capability] = capability
    guard let grants = try? decoder.decode(Grants.self, from: data) else {
      throw ServerError.forbidden("no valid \(capability) grant")
    }

    var result = Capabilities()
    for grant in grants.grants {
      for (api, level) in grant {
        let access: Access = level == .rw ? .write : .read
        switch api {
        case .graphql: result.graphql = max(result.graphql, access)
        case .mcp: result.mcp = max(result.mcp, access)
        case .metrics:
          guard access == .read else { throw ServerError.forbidden("metrics grants are read-only") }
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

  // An unknown path is allowed through so the server can answer 404.
  func access(_ route: Route?) -> Access {
    switch route {
    case .graphql: return graphql
    case .mcp: return mcp
    case .metrics: return metrics
    case nil: return .write
    }
  }

  // Serve uses RFC2047 UTF-8 Q encoding for non-ASCII capability values.
  // Adjacent encoded words may be separated by whitespace.
  private static func decodeHeader(_ header: String) throws -> Data {
    guard header.hasPrefix("=?") else { return Data(header.utf8) }
    var decoded = Data()
    for word in header.split(whereSeparator: { $0.isWhitespace }) {
      guard word.lowercased().hasPrefix("=?utf-8?q?"), word.hasSuffix("?=") else {
        throw ServerError.forbidden("malformed capability header encoding")
      }
      let bytes = Array(word.dropFirst(10).dropLast(2).utf8)
      var index = 0
      while index < bytes.count {
        switch bytes[index] {
        case 61:
          guard index + 2 < bytes.count else {
            throw ServerError.forbidden("malformed capability header encoding")
          }
          let hex = bytes[(index + 1)...(index + 2)]
          guard hex.allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
            let byte = UInt8(String(decoding: hex, as: UTF8.self), radix: 16)
          else { throw ServerError.forbidden("malformed capability header encoding") }
          decoded.append(byte)
          index += 3
        case 95:
          decoded.append(32)
          index += 1
        default:
          guard (33...126).contains(bytes[index]), bytes[index] != 63 else {
            throw ServerError.forbidden("malformed capability header encoding")
          }
          decoded.append(bytes[index])
          index += 1
        }
      }
    }
    guard String(data: decoded, encoding: .utf8) != nil else {
      throw ServerError.forbidden("malformed capability header encoding")
    }
    return decoded
  }
}
