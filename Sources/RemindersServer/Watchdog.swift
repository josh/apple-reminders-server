import Foundation
import struct os.OSAllocatedUnfairLock

// A synchronous framework call (a stalled TCC lookup) can hold the main actor for
// minutes, and no request deadline can free it, so the process exits for launchd
// to restart once the main queue stops draining.
func startMainActorWatchdog(limit: Duration = .seconds(120), interval: TimeInterval = 10) {
  let clock = ContinuousClock()
  let lastBeat = OSAllocatedUnfairLock(initialState: clock.now)
  Thread.detachNewThread {
    while true {
      Thread.sleep(forTimeInterval: interval)
      let silent = lastBeat.withLock { $0 }.duration(to: clock.now)
      if silent > limit {
        serverLogger.critical(
          "Main actor unresponsive; exiting",
          metadata: ["silent_seconds": "\(silent.components.seconds)"])
        exit(1)
      }
      DispatchQueue.main.async { lastBeat.withLock { $0 = clock.now } }
    }
  }
}
