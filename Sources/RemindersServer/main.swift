import Darwin
import Foundation
import Logging

import struct os.OSAllocatedUnfairLock

let usage = """
  Usage: apple-reminders-server

  Serves /graphql, /mcp, and /metrics on the sockets launchd hands it. Start it from a
  LaunchAgent plist; run directly, it exits.

  Socket labels: \(SocketLabel.allCases.map(\.rawValue).joined(separator: ", "))
  Environment variables:
  \(ConfigVariable.allCases.map { "  \($0.rawValue)" }.joined(separator: "\n"))

  See https://github.com/josh/apple-reminders-server/blob/main/docs/SERVER.md
  """

// launchd starts the server and owns its sockets; REMINDERS_* environment variables in
// the plist configure it. The only arguments are --help and the developer dumps of the
// API docs.
Task.detached {
  do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print(usage)
    } else if arguments == ["--dump-mcp-tools"] {
      print(try mcpToolsJSON())
    } else if arguments == ["--dump-graphql-schema"] {
      print(try graphQLSchemaSDL())
    } else if !arguments.isEmpty {
      throw ServerError.internalError(
        "Use --help; the server is configured by REMINDERS_* variables in its launchd plist")
    } else {
      let config = try ServerConfig(environment: ProcessInfo.processInfo.environment)
      let sockets = try activateLaunchdSockets()
      if sockets.contains(where: { $0.label == .tailscaleServe }),
        config.tailscaleAppCapability == nil
      {
        throw ServerError.internalError(
          "The TailscaleServe socket requires \(ConfigVariable.tailscaleAppCapability.rawValue)")
      }
      serverLogger.logLevel = config.logLevel
      startMainActorWatchdog()
      // With access already granted there is nothing to request, so requests need not wait
      // behind the main actor for it.
      let requestAccess = config.requestAccess && (try? requireAccess()) == nil
      let authorizing = OSAllocatedUnfairLock(initialState: requestAccess)
      if requestAccess {
        Task { @MainActor in
          do {
            try await authorizeReminders()
            authorizing.withLock { $0 = false }
          } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
          }
        }
      }
      try await serve(sockets: sockets, config: config, authorizing: authorizing)
    }

    exit(0)
  } catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
  }

}
// The main thread drains the main queue, which runs the main actor for EventKit and AppleScript.
dispatchMain()
