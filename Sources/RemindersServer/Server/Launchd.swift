import Darwin
import launch

// Keys of the launchd plist's Sockets dictionary. The label a connection arrived on,
// never a request header, decides how it is trusted.
enum SocketLabel: String, CaseIterable, Sendable {
  // The default: full access; the plist's socket mode or address limits who can connect.
  case listeners = "Listeners"
  // One API each, with full access to it and nothing else.
  case metrics = "Metrics"
  case graphql = "GraphQL"
  case mcp = "MCP"
  // Tailscale Serve forwards here; each request needs an app-capability grant.
  case tailscaleServe = "TailscaleServe"
}

struct LaunchdSocket: Sendable {
  let label: SocketLabel
  let descriptor: CInt
}

// Takes the listening sockets launchd created for this job. A label may carry several
// descriptors, such as IPv4 and IPv6 for one TCP port.
func activateLaunchdSockets() throws -> [LaunchdSocket] {
  var sockets: [LaunchdSocket] = []
  for label in SocketLabel.allCases {
    // launchd fills in a malloc'd descriptor array only on success.
    let array = UnsafeMutablePointer<UnsafeMutablePointer<CInt>>.allocate(capacity: 1)
    defer { array.deallocate() }
    var count = 0
    let status = launch_activate_socket(label.rawValue, array, &count)
    switch status {
    case 0:
      let descriptors = array.pointee
      defer { free(descriptors) }
      for index in 0..<count {
        sockets.append(LaunchdSocket(label: label, descriptor: descriptors[index]))
      }
    // A label the plist does not define returns ENOENT or, in practice, ESRCH; ESRCH is
    // also what a process outside launchd gets, which the empty check below reports.
    case ENOENT, ESRCH: continue
    default:
      throw ServerError.internalError(
        "Cannot activate launchd socket \(label.rawValue) (errno \(status))")
    }
  }
  guard !sockets.isEmpty else {
    throw ServerError.internalError(
      "Start the server through launchd with a Listeners, Metrics, GraphQL, MCP, or TailscaleServe socket"
    )
  }
  return sockets
}
