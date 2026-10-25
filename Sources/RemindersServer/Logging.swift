import Foundation
import Logging

var serverLogger = Logger(label: "apple-reminders-server") {
  StreamLogHandler.standardError(label: $0)
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
