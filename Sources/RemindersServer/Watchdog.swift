import Foundation
import struct os.OSAllocatedUnfairLock

private let heartbeatClock = ContinuousClock()
private let lastHeartbeat = OSAllocatedUnfairLock(initialState: heartbeatClock.now)

func mainActorHeartbeatAge() -> Duration {
  lastHeartbeat.withLock { $0 }.duration(to: heartbeatClock.now)
}

// A synchronous framework call (a stalled TCC lookup) can hold the main actor for
// minutes, and no request deadline can free it, so the process exits for launchd
// to restart once the main queue stops draining.
func startMainActorWatchdog(limit: Duration = .seconds(120), interval: TimeInterval = 10) {
  Thread.detachNewThread {
    while true {
      Thread.sleep(forTimeInterval: interval)
      let silent = mainActorHeartbeatAge()
      if silent > limit {
        serverLogger.critical(
          "Main actor unresponsive; exiting",
          metadata: ["silent_seconds": "\(silent.components.seconds)"])
        exit(1)
      }
      DispatchQueue.main.async { lastHeartbeat.withLock { $0 = heartbeatClock.now } }
    }
  }
}
