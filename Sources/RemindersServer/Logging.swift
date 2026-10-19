import Foundation
import Logging

var serverLogger = Logger(label: "apple-reminders-server") { label in
  var handler = StreamLogHandler.standardError(label: label)
  handler.logLevel = .info
  return handler
}

func logFailure(_ message: String, error: Error) {
  let native = error as NSError
  serverLogger.error(
    "\(message)",
    metadata: [
      "error_type": "\(type(of: error))",
      "error_domain": "\(native.domain)",
      "error_code": "\(native.code)",
    ])
}

extension ServiceResponse {
  var failureKind: String? {
    if status >= 400 { return "http" }
    if classified { return failure }
    // Only MCP protocol replies arrive unclassified; GraphQL and tool calls classify.
    guard type.hasPrefix("application/json"),
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return nil }
    return object["error"] != nil ? "mcp_protocol" : nil
  }
}
