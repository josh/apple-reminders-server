import Foundation

struct Capabilities {
  enum Access: Int {
    case denied, read, write
  }

  var graphql: Access = .denied
  var mcp: Access = .denied
  var metrics: Access = .denied

  static func parse(header: String?, capability: String?) throws -> Capabilities {
    guard let capability, let header else {
      return Capabilities(graphql: .write, mcp: .write, metrics: .read)
    }
    guard header.utf8.count <= 16_384,
      let object = try JSONSerialization.jsonObject(with: decodeHeader(header)) as? [String: Any],
      let grants = object[capability] as? [[String: Any]]
    else { throw ServerError.forbidden("Forbidden") }

    var result = Capabilities()
    for grant in grants {
      for (name, value) in grant {
        guard let value = value as? String, value == "r" || value == "rw" else {
          throw ServerError.forbidden("Forbidden")
        }
        let access: Access = value == "rw" ? .write : .read
        switch name {
        case "graphql": result.graphql = maxAccess(result.graphql, access)
        case "mcp": result.mcp = maxAccess(result.mcp, access)
        case "metrics":
          guard access == .read else { throw ServerError.forbidden("Forbidden") }
          result.metrics = .read
        default: throw ServerError.forbidden("Forbidden")
        }
      }
    }
    return result
  }

  func allows(path: String) -> Bool {
    switch path {
    case "/graphql": return graphql != .denied
    case "/mcp": return mcp != .denied
    case "/metrics": return metrics != .denied
    default: return true
    }
  }

  private static func maxAccess(_ lhs: Access, _ rhs: Access) -> Access {
    lhs.rawValue >= rhs.rawValue ? lhs : rhs
  }

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
