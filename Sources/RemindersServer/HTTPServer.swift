import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

import struct os.OSAllocatedUnfairLock

// Why a request is logged as failed; the raw value is the log's outcome label.
enum Failure: String {
  case http
  case graphql
  case mcpTool = "mcp_tool"
  case mcpProtocol = "mcp_protocol"
}
struct ServiceResponse {
  var status: HTTPResponseStatus = .ok
  var headers: HTTPHeaders = ["Content-Type": "application/json"]
  var body: Data
  // Set by the handler that knows the outcome of a successful HTTP response.
  var failure: Failure? = nil
  // Extra request details the handler wants logged.
  var logMetadata: [String: String] = [:]
  // A JSON body with sorted keys.
  static func json<Body: Encodable>(
    _ body: Body, status: HTTPResponseStatus = .ok, failure: Failure? = nil
  ) -> ServiceResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // Bodies here are plain structs of strings, which always encode.
    return ServiceResponse(status: status, body: try! encoder.encode(body), failure: failure)
  }
  // {"error": message}, the body of every failure outside GraphQL's own error format. The
  // message is logged too, since the status alone does not say which check failed.
  static func error(_ message: String, status: HTTPResponseStatus) -> ServiceResponse {
    var response = ServiceResponse.json(ErrorBody(error: message), status: status)
    response.logMetadata["error"] = message
    return response
  }
}
private struct ErrorBody: Encodable { let error: String }

// The served endpoints; any other path is logged and counted as "other".
enum Route: String {
  case graphql = "/graphql"
  case mcp = "/mcp"
  case metrics = "/metrics"
}

// One API endpoint: method, merged lowercase headers, body, and the caller's access.
typealias APIHandler =
  @Sendable (HTTPMethod, [String: String], Data, Capabilities.Access) async throws
  -> ServiceResponse

// Request headers the server reads itself, by lowercase name.
private enum RequestHeader: String {
  case origin
  case contentType = "content-type"
  case appCapabilities = "tailscale-app-capabilities"
  case userLogin = "tailscale-user-login"
  case userAgent = "user-agent"
  case corsRequestHeaders = "access-control-request-headers"
  case forwardedFor = "x-forwarded-for"
  // Read as one value, so a repeat is ambiguous. Every other header may repeat per
  // RFC 9110 and is joined with a comma, as proxies expect.
  var isSingleValue: Bool { [.origin, .contentType, .appCapabilities].contains(self) }
}
extension [String: String] {
  fileprivate subscript(header header: RequestHeader) -> String? { self[header.rawValue] }
}

private let requestDeadline: Duration = .seconds(60)
private struct RequestTimedOut: Error {}
// A task group returns only once every child has, and cancellation cannot interrupt a
// synchronous framework call holding the main actor, so the deadline resumes the caller
// itself and leaves the stuck operation cancelled behind it.
private func withRequestDeadline<T: Sendable>(
  _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
  let pending = OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>(initialState: nil)
  let work = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
  let settle: @Sendable (Result<T, Error>) -> Void = { result in
    pending.withLock { continuation in
      continuation?.resume(with: result)
      continuation = nil
    }
  }
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      pending.withLock { $0 = continuation }
      let task = Task {
        do { settle(.success(try await operation())) } catch { settle(.failure(error)) }
      }
      work.withLock { $0 = task }
      Task {
        guard (try? await Task.sleep(for: requestDeadline)) != nil else { return }
        task.cancel()
        settle(.failure(RequestTimedOut()))
      }
    }
  } onCancel: {
    work.withLock { $0 }?.cancel()
  }
}

func serve(
  sockets: [LaunchdSocket], config: ServerConfig, authorizing: OSAllocatedUnfairLock<Bool>
) async throws {
  let metricsCollector = MetricsCollector()
  let collectionTask = Task {
    await metricsCollector.run(intervalSeconds: config.metricsInterval)
  }
  defer { collectionTask.cancel() }
  let handlers: [Route: APIHandler] = [
    .graphql: try makeGraphQLHandler(),
    .mcp: handleMCP,
  ]
  let origins = Set(config.allowedOrigins)
  let responder: Responder = { request in
    let started = ContinuousClock.now
    let route = Route(rawValue: request.path)
    // Repeats are joined here; a repeated single-value header is rejected below.
    var headers: [String: String] = [:]
    var repeated: String?
    for (name, value) in request.head.headers {
      let key = name.lowercased()
      guard let existing = headers[key] else {
        headers[key] = value
        continue
      }
      if RequestHeader(rawValue: key)?.isSingleValue == true { repeated = repeated ?? key }
      headers[key] = existing + ", " + value
    }
    func respond(_ response: ServiceResponse) -> ServiceResponse {
      let milliseconds = started.duration(to: .now) / .milliseconds(1)
      let routeName = route?.rawValue ?? "other"
      // MCP clients probe for an event stream with GET; the spec answer is 405.
      let code = Int(response.status.code)
      let probe =
        request.head.method == .GET && route == .mcp && response.status == .methodNotAllowed
      let failure = probe ? nil : code >= 400 ? .http : response.failure
      let level: Logger.Level = code >= 500 ? .error : failure == nil ? .debug : .notice
      var metadata: Logger.Metadata = [
        "method": "\(request.head.method.rawValue)", "route": "\(routeName)",
        "status": "\(code)", "duration_ms": "\(String(format: "%.2f", milliseconds))",
        "outcome": "\(failure?.rawValue ?? "ok")",
      ]
      // Tailscale serve forwards the peer address and, for user-owned nodes, the login.
      if let peer = headers[header: .forwardedFor] { metadata["peer"] = "\(peer)" }
      if let login = headers[header: .userLogin] { metadata["tailscale_user"] = "\(login)" }
      if let agent = headers[header: .userAgent] { metadata["user_agent"] = "\(agent)" }
      for (key, value) in response.logMetadata { metadata[key] = "\(value)" }
      serverLogger.log(level: level, "HTTP request", metadata: metadata)
      recordRequest(route: routeName, code: code)
      var cors = response
      if let origin = headers[header: .origin], origins.contains(origin.lowercased()) {
        cors.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: origin)
        cors.headers.replaceOrAdd(name: "Vary", value: "Origin")
      }
      return cors
    }
    do {
      let response: ServiceResponse
      if let key = repeated {
        return respond(.error("Repeated \(key) header", status: .badRequest))
      }
      if let origin = headers[header: .origin], !origins.contains(origin.lowercased()) {
        response = .error("Untrusted origin", status: .forbidden)
      } else if request.head.method == .OPTIONS {
        var preflight = ServiceResponse(status: .noContent, body: Data())
        preflight.headers.add(name: "Allow", value: "GET, POST, OPTIONS")
        if headers[header: .origin] != nil {
          preflight.headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
          preflight.headers.add(
            name: "Access-Control-Allow-Headers",
            value: headers[header: .corsRequestHeaders]
              ?? "Content-Type, Accept, Mcp-Protocol-Version")
          preflight.headers.add(name: "Access-Control-Max-Age", value: "86400")
        }
        response = preflight
      } else if request.head.method == .POST
        && headers[header: .contentType]?.split(separator: ";").first?.trimmingCharacters(
          in: .whitespaces
        )
        .lowercased() != "application/json"
      {
        response = .error("Content-Type application/json required", status: .unsupportedMediaType)
      } else {
        // Denials log their reason; the response stays a bare "Forbidden".
        func forbidden(_ reason: String) -> ServiceResponse {
          var response = ServiceResponse.error("Forbidden", status: .forbidden)
          response.logMetadata["error"] = reason
          return response
        }
        let capabilities: Capabilities
        switch request.label {
        case .listeners: capabilities = .full
        case .metrics: capabilities = .metricsOnly
        case .graphql: capabilities = .graphqlOnly
        case .mcp: capabilities = .mcpOnly
        case .tailscaleServe:
          // main refuses to start a TailscaleServe socket without the capability name.
          do {
            capabilities = try Capabilities.parse(
              header: headers[header: .appCapabilities],
              capability: config.tailscaleAppCapability ?? "")
          } catch {
            return respond(forbidden("\(error)"))
          }
        }
        let access = capabilities.access(route)
        guard access != .denied else {
          return respond(forbidden("\(request.label.rawValue) access does not include this route"))
        }
        if route != .metrics && authorizing.withLock({ $0 }) {
          return respond(.error("Reminders authorization pending", status: .serviceUnavailable))
        }
        guard let body = request.body else {
          return respond(ServiceResponse(status: .payloadTooLarge, body: Data()))
        }
        if route == .metrics && request.head.method == .GET {
          let eventKit = await metricsCollector.exposition
          let runtime = runtimeMetrics(
            eventKitUp: eventKit != nil, authorizing: authorizing.withLock { $0 })
          response = ServiceResponse(
            headers: ["Content-Type": "text/plain; version=0.0.4; charset=utf-8"],
            body: Data((runtime + (eventKit ?? "")).utf8))
        } else if let route, let handler = handlers[route] {
          let method = request.head.method
          let requestHeaders = headers
          response = try await withRequestDeadline {
            try await handler(method, requestHeaders, body, access)
          }
        } else {
          response = .error("Not found", status: .notFound)
        }
      }
      return respond(response)
    } catch is RequestTimedOut {
      return respond(.error("Request timed out", status: .gatewayTimeout))
    } catch {
      logFailure("Request failed", error: error)
      return respond(.error("Internal server error", status: .internalServerError))
    }
  }
  let idle = config.exitWhenIdle.map(IdleExit.init)
  try await listen(sockets: sockets, idle: idle, responder: responder)
}

// One HTTP/1.1 request with its body collected; nil when the body exceeded the limit.
struct CollectedRequest: Sendable {
  let label: SocketLabel
  let head: HTTPRequestHead
  let body: Data?
  var path: String { String(head.uri.prefix { $0 != "?" }) }
}
typealias Responder = @Sendable (CollectedRequest) async -> ServiceResponse
private let maxBodyBytes = 1_048_576

// Serves HTTP/1.1 on launchd's sockets until the process exits. NIO parses requests,
// answers malformed ones with 400, and handles keep-alive and pipelining.
private func listen(sockets: [LaunchdSocket], idle: IdleExit?, responder: @escaping Responder)
  async throws
{
  try await withThrowingDiscardingTaskGroup { group in
    for socket in sockets {
      let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        // A client may half-close after sending; keep writing its responses.
        .childChannelOption(.allowRemoteHalfClosure, value: true)
        .bind(socket.descriptor) { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
              withErrorHandling: true)
            return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
              wrappingChannelSynchronously: channel)
          }
        }
      // launchd binds unix sockets at a temporary path and renames them into place, so only
      // a TCP address is worth logging.
      let address = server.channel.localAddress
      let host = address?.ipAddress.map { $0.contains(":") ? "[\($0)]" : $0 } ?? "?"
      let location = address?.protocol == .unix ? "(unix)" : "at \(host):\(address?.port ?? 0)"
      serverLogger.info("Listening on launchd socket \(socket.label.rawValue) \(location)")
      group.addTask {
        try await server.executeThenClose { connections in
          try await withThrowingDiscardingTaskGroup { open in
            for try await connection in connections {
              idle?.opened()
              open.addTask {
                await serveConnection(connection, label: socket.label, responder: responder)
                idle?.closed()
              }
            }
          }
        }
      }
    }
    if let idle { group.addTask { await idle.run() } }
  }
}

// Exits once no connection has been open for the window. launchd keeps the sockets and
// starts the server again on the next connection.
final class IdleExit: Sendable {
  private let window: Duration
  private let state = OSAllocatedUnfairLock(
    initialState: (open: 0, since: ContinuousClock.now))
  init(window: Duration) { self.window = window }
  func opened() { state.withLock { $0.open += 1 } }
  func closed() {
    state.withLock {
      $0.open -= 1
      $0.since = .now
    }
  }
  func run() async {
    while (try? await Task.sleep(for: min(window, .seconds(5)))) != nil {
      let idle = state.withLock { $0.open == 0 && $0.since.duration(to: .now) >= window }
      if idle {
        serverLogger.info("Exiting after \(window) without connections")
        exit(0)
      }
    }
  }
}

private func serveConnection(
  _ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
  label: SocketLabel, responder: Responder
) async {
  // A connection error only ends that connection; NIO has already answered parse errors.
  try? await connection.executeThenClose { inbound, outbound in
    var head: HTTPRequestHead?
    var body = ByteBuffer()
    var oversized = false
    for try await part in inbound {
      switch part {
      case .head(let value):
        head = value
        body.clear()
        oversized = false
      case .body(var chunk):
        if oversized || body.readableBytes + chunk.readableBytes > maxBodyBytes {
          oversized = true
          body.clear()
        } else {
          body.writeBuffer(&chunk)
        }
      case .end:
        guard let request = head else { continue }
        let response = await responder(
          CollectedRequest(
            label: label, head: request, body: oversized ? nil : Data(body.readableBytesView)))
        var headers = response.headers
        if response.status != .noContent {
          headers.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        }
        headers.add(name: "Date", value: Date().formatted(httpDate))
        try await outbound.write(
          .head(
            HTTPResponseHead(
              version: .http1_1, status: response.status, headers: headers)))
        if request.method != .HEAD && !response.body.isEmpty {
          try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: response.body))))
        }
        try await outbound.write(.end(nil))
        guard request.isKeepAlive else { return }
        head = nil
      }
    }
  }
}

// IMF-fixdate (RFC 9110), for the Date header.
private let httpDate = Date.VerbatimFormatStyle(
  format:
    "\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT",
  locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt,
  calendar: Calendar(identifier: .gregorian))
