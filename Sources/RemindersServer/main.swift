import Darwin
import Foundation

let usage = """
  Usage: apple-reminders-server [--port 8171] [--request-access] [--metrics-interval-seconds 3600] [--allowed-origin <origin>]... [--tailscale-app-capability <name>]

  Serve /graphql, /mcp, and /metrics on 127.0.0.1. Requires macOS 14+.
  --metrics-interval-seconds sets the background metrics refresh delay (default: 3600).
  Loopback origins are always allowed; each --allowed-origin adds a browser origin
  that may call the server cross-origin.
  --tailscale-app-capability applies Tailscale permissions when given.
  --request-access explicitly requests permission in the serving process at startup.

  GraphQL and MCP support reminder create/update/delete in editable lists.
  Server configuration uses explicit startup options only, never environment variables.
  GraphQL reads flags, alert dates, emblems, and containers through Reminders
  automation only when selected or filtered, which may prompt for Automation
  permission; MCP reads use EventKit alone. Flag, alert-date, and emblem writes
  use automation after the EventKit save. EventKit prompts only at explicit startup.
  """

Task.detached {
  do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print(usage)
    } else {
      var port: UInt16 = 8171
      var metricsInterval = 3600
      var requestAccess = false
      var allowedOrigins: [String] = []
      var tailscaleAppCapability: String?
      var index = 0
      var seen = Set<String>()
      while index < arguments.count {
        let option = arguments[index]
        guard option == "--allowed-origin" || seen.insert(option).inserted else {
          throw ServerError.internalError("Duplicate option: \(option)")
        }
        switch option {
        case "--request-access": requestAccess = true
        case "--port", "--metrics-interval-seconds", "--allowed-origin",
          "--tailscale-app-capability":
          index += 1
          guard index < arguments.count else {
            throw ServerError.internalError("Missing value for \(option)")
          }
          if option == "--tailscale-app-capability" {
            let value = arguments[index]
            let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !value.contains(where: { $0.isWhitespace }), !value.hasPrefix("--")
            else { throw ServerError.internalError("Capability must be a domain/path name") }
            tailscaleAppCapability = value
          } else if option == "--allowed-origin" {
            let value = arguments[index]
            guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil,
              let components = URLComponents(string: value),
              components.percentEncodedPath.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("\n"), !value.contains("\r")
            else {
              throw ServerError.internalError(
                "Allowed origin must be http://host[:port] or https://host[:port], without a path, query, or fragment"
              )
            }
            allowedOrigins.append("\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? ""))
          } else if option == "--port" {
            guard let value = UInt16(arguments[index]), value > 0 else {
              throw ServerError.internalError("Port must be between 1 and 65535")
            }
            port = value
          } else {
            guard let value = Int(arguments[index]), (1...604800).contains(value) else {
              throw ServerError.internalError(
                "Metrics interval must be between 1 and 604800 seconds")
            }
            metricsInterval = value
          }
        default: throw ServerError.internalError("Use --help for server options")
        }
        index += 1
      }
      if requestAccess {
        try await withReminders { try authorizeReminders() }
      }
      try await serve(
        port: port, metricsInterval: metricsInterval, allowedOrigins: allowedOrigins,
        tailscaleAppCapability: tailscaleAppCapability)
    }

    exit(0)
  } catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
  }

}
// Keep the actual main thread available for serialized NSAppleScript execution.
remindersRunMainLoop()
