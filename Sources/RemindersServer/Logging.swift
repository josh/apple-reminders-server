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
