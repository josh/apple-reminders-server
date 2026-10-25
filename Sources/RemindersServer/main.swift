import Darwin
import Foundation
import Logging

import struct os.OSAllocatedUnfairLock

// launchd starts the server and owns its sockets; REMINDERS_* environment variables in
// the plist configure it. The only arguments are the developer dumps of the API docs.
Task.detached {
  do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--dump-mcp-tools"] {
      print(try mcpToolsJSON())
    } else if arguments == ["--dump-graphql-schema"] {
      print(try graphQLSchemaSDL())
    } else if !arguments.isEmpty {
      throw ServerError.internalError(
        "The server takes no arguments; set REMINDERS_* variables in its launchd plist")
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
      let authorizing = OSAllocatedUnfairLock(initialState: config.requestAccess)
      if config.requestAccess {
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
