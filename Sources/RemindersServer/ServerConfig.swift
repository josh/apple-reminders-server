import Foundation
import Logging

// Environment variables the launchd plist sets in EnvironmentVariables.
enum ConfigVariable: String, CaseIterable {
  case tailscaleAppCapability = "REMINDERS_TAILSCALE_APP_CAPABILITY"
  case allowedOrigins = "REMINDERS_ALLOWED_ORIGINS"
  case exitWhenIdleSeconds = "REMINDERS_EXIT_WHEN_IDLE_SECONDS"
  case logLevel = "REMINDERS_LOG_LEVEL"
  case metricsIntervalSeconds = "REMINDERS_METRICS_INTERVAL_SECONDS"
  case requestAccess = "REMINDERS_REQUEST_ACCESS"
}

// Server configuration, read once at startup. An invalid value stops the server; other
// environment variables are ignored.
struct ServerConfig: Sendable {
  var tailscaleAppCapability: String?
  var allowedOrigins: [String] = []
  var exitWhenIdle: Duration?
  var logLevel: Logger.Level = .info
  var metricsInterval = 3600
  var requestAccess = false

  init(environment: [String: String]) throws {
    for variable in ConfigVariable.allCases {
      guard let value = environment[variable.rawValue] else { continue }
      switch variable {
      case .tailscaleAppCapability:
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
          !value.contains(where: { $0.isWhitespace })
        else { throw invalid(variable, "must be a domain/path capability name") }
        tailscaleAppCapability = value
      case .allowedOrigins:
        allowedOrigins = try value.split(separator: " ").map { try origin(String($0)) }
      case .exitWhenIdleSeconds:
        guard let seconds = Int(value), (1...86400).contains(seconds) else {
          throw invalid(variable, "must be between 1 and 86400 seconds")
        }
        exitWhenIdle = .seconds(seconds)
      case .logLevel:
        guard let level = Logger.Level(rawValue: value) else {
          throw invalid(
            variable, "must be trace, debug, info, notice, warning, error, or critical")
        }
        logLevel = level
      case .metricsIntervalSeconds:
        guard let seconds = Int(value), (1...604800).contains(seconds) else {
          throw invalid(variable, "must be between 1 and 604800 seconds")
        }
        metricsInterval = seconds
      case .requestAccess:
        guard value == "1" else { throw invalid(variable, "must be 1 when set") }
        requestAccess = true
      }
    }
  }
}

private func invalid(_ variable: ConfigVariable, _ rule: String) -> ServerError {
  .internalError("\(variable.rawValue) \(rule)")
}

// Normalizes one allowed browser origin to scheme://host[:port], dropping a default port.
private func origin(_ value: String) throws -> String {
  guard let url = URL(string: value),
    let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
    let host = url.host?.lowercased(), !host.isEmpty,
    url.path.isEmpty, url.query == nil, url.fragment == nil,
    url.user == nil, url.password == nil,
    let components = URLComponents(string: value),
    components.percentEncodedPath.isEmpty
  else {
    throw invalid(
      .allowedOrigins,
      "entries must be http://host[:port] or https://host[:port], without a path, query, or fragment"
    )
  }
  let defaultPort = scheme == "https" ? 443 : 80
  let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
  return "\(scheme)://\(host)\(port)"
}
