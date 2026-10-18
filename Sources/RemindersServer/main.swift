import Darwin
import Foundation

let usage = """
  Usage: apple-reminders-server [--port 8081] [--request-access] [--metrics-interval-seconds 3600]

  Serve /graphql, /mcp, and /metrics on 127.0.0.1. Requires macOS 14+.
  --metrics-interval-seconds sets the background metrics refresh delay (default: 3600).
  --request-access explicitly requests permission in the serving process at startup.

  GraphQL and MCP support reminder create/update/delete in editable lists.
  Server configuration uses explicit startup options only, never environment variables.
  Reminders flag reads always use Reminders
  automation and may prompt for Automation permission; EventKit prompts only at
  explicit startup. GraphQL reads flags only when selected or filtered.
  """

Task.detached {
  do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print(usage)
    } else {
      var port: UInt16 = 8081
      var metricsInterval = 3600
      var requestAccess = false
      var index = 0
      var seen = Set<String>()
      while index < arguments.count {
        let option = arguments[index]
        guard seen.insert(option).inserted else {
          throw ServerError.message("Duplicate option: \(option)")
        }
        switch option {
        case "--request-access": requestAccess = true
        case "--port", "--metrics-interval-seconds":
          index += 1
          guard index < arguments.count else {
            throw ServerError.message("Missing value for \(option)")
          }
          if option == "--port" {
            guard let value = UInt16(arguments[index]), value > 0 else {
              throw ServerError.message("Port must be between 1 and 65535")
            }
            port = value
          } else {
            guard let value = Int(arguments[index]), (1...604800).contains(value) else {
              throw ServerError.message("Metrics interval must be between 1 and 604800 seconds")
            }
            metricsInterval = value
          }
        default: throw ServerError.message("Use --help for server options")
        }
        index += 1
      }
      if requestAccess {
        try await withReminders { try authorizeReminders() }
      }
      try await serve(port: port, metricsInterval: metricsInterval)
    }

    exit(0)
  } catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
  }

}
// Keep the actual main thread available for serialized NSAppleScript execution.
remindersRunMainLoop()
