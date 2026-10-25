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
  var status: Int = 200
  var type = "application/json"
  var body: Data
  var headers: [String: String] = [:]
  // Set by the handler that knows the outcome of a successful HTTP response.
  var failure: Failure? = nil
  // Extra request details the handler wants logged.
  var logMetadata: [String: String] = [:]
  // A JSON body with sorted keys.
  static func json<Body: Encodable>(_ body: Body, status: Int = 200, failure: Failure? = nil)
    -> ServiceResponse
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // Bodies here are plain structs of strings, which always encode.
    return ServiceResponse(status: status, body: try! encoder.encode(body), failure: failure)
  }
  // {"error": message}, the body of every failure outside GraphQL's own error format.
  static func error(_ message: String, status: Int) -> ServiceResponse {
    .json(ErrorBody(error: message), status: status)
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

// Headers the server reads as one value; a repeat is ambiguous. Every other header
// may repeat per RFC 9110 and is joined with a comma, as proxies expect.
private let singleValueHeaders: Set<String> = [
  "origin", "content-type", "tailscale-app-capabilities",
]
private let proxyHeaders: Set<String> = [
  "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "forwarded",
  "tailscale-funnel-request",
]

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
  port: UInt16, metricsInterval: Int, allowedOrigins: [String], tailscaleAppCapability: String?,
  authorizing: OSAllocatedUnfairLock<Bool>
) async throws {
  let metricsCollector = MetricsCollector()
  let collectionTask = Task { await metricsCollector.run(intervalSeconds: metricsInterval) }
  defer { collectionTask.cancel() }
  let handlers: [Route: APIHandler] = [
    .graphql: try makeGraphQLHandler(),
    .mcp: { try await handleMCP(method: $0, headers: $1, body: $2, access: $3) },
  ]
  let origins = Set(["http://127.0.0.1:\(port)", "http://localhost:\(port)"] + allowedOrigins)
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
      if singleValueHeaders.contains(key) { repeated = repeated ?? key }
      headers[key] = existing + ", " + value
    }
    func respond(_ response: ServiceResponse) -> ServiceResponse {
      let elapsed = started.duration(to: .now).components
      let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
      let routeName = route?.rawValue ?? "other"
      // MCP clients probe for an event stream with GET; the spec answer is 405.
      let probe = request.head.method == .GET && route == .mcp && response.status == 405
      let failure = probe ? nil : response.status >= 400 ? .http : response.failure
      let level: Logger.Level =
        response.status >= 500 ? .error : failure == nil ? .debug : .notice
      var metadata: Logger.Metadata = [
        "method": "\(request.head.method.rawValue)", "route": "\(routeName)",
        "status": "\(response.status)", "duration_ms": "\(String(format: "%.2f", milliseconds))",
        "outcome": "\(failure?.rawValue ?? "ok")",
      ]
      // Tailscale serve forwards the peer address and, for user-owned nodes, the login.
      if let peer = headers["x-forwarded-for"] { metadata["peer"] = "\(peer)" }
      if let login = headers["tailscale-user-login"] { metadata["tailscale_user"] = "\(login)" }
      if let agent = headers["user-agent"] { metadata["user_agent"] = "\(agent)" }
      for (key, value) in response.logMetadata { metadata[key] = "\(value)" }
      serverLogger.log(level: level, "HTTP request", metadata: metadata)
      recordRequest(route: routeName, code: response.status)
      var cors = response
      if let origin = headers["origin"], origins.contains(origin.lowercased()) {
        cors.headers["Access-Control-Allow-Origin"] = origin
        cors.headers["Vary"] = "Origin"
      }
      return cors
    }
    do {
      let response: ServiceResponse
      if let key = repeated {
        return respond(.error("Repeated \(key) header", status: 400))
      }
      if let origin = headers["origin"], !origins.contains(origin.lowercased()) {
        response = .error("Untrusted origin", status: 403)
      } else if request.head.method == .OPTIONS {
        var preflightHeaders = ["Allow": "GET, POST, OPTIONS"]
        if headers["origin"] != nil {
          preflightHeaders["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
          preflightHeaders["Access-Control-Allow-Headers"] =
            headers["access-control-request-headers"]
            ?? "Content-Type, Accept, Mcp-Protocol-Version"
          preflightHeaders["Access-Control-Max-Age"] = "86400"
        }
        response = ServiceResponse(status: 204, body: Data(), headers: preflightHeaders)
      } else if request.head.method == .POST
        && headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(
          in: .whitespaces
        )
        .lowercased() != "application/json"
      {
        response = .error("Content-Type application/json required", status: 415)
      } else {
        guard
          let capabilities = try? Capabilities.parse(
            header: headers["tailscale-app-capabilities"], capability: tailscaleAppCapability,
            proxied: headers.keys.contains(where: proxyHeaders.contains)),
          capabilities.allows(route)
        else { return respond(.error("Forbidden", status: 403)) }
        if route != .metrics && authorizing.withLock({ $0 }) {
          return respond(.error("Reminders authorization pending", status: 503))
        }
        guard let body = request.body else {
          return respond(ServiceResponse(status: 413, body: Data()))
        }
        if route == .metrics && request.head.method == .GET {
          let eventKit = await metricsCollector.cachedExposition()
          let runtime = runtimeMetrics(
            eventKitUp: eventKit != nil, authorizing: authorizing.withLock { $0 })
          response = ServiceResponse(
            type: "text/plain; version=0.0.4; charset=utf-8",
            body: Data((runtime + (eventKit ?? "")).utf8))
        } else if let route, let handler = handlers[route] {
          let method = request.head.method
          let requestHeaders = headers
          let access = capabilities.access(route)
          response = try await withRequestDeadline {
            try await handler(method, requestHeaders, body, access)
          }
        } else {
          response = .error("Not found", status: 404)
        }
      }
      return respond(response)
    } catch is RequestTimedOut {
      return respond(.error("Request timed out", status: 504))
    } catch {
      logFailure("Request failed", error: error)
      return respond(.error("Internal server error", status: 500))
    }
  }
  try await listen(port: port, responder: responder)
}

// One HTTP/1.1 request with its body collected; nil when the body exceeded the limit.
struct CollectedRequest: Sendable {
  let head: HTTPRequestHead
  let body: Data?
  var path: String { String(head.uri.prefix { $0 != "?" }) }
}
typealias Responder = @Sendable (CollectedRequest) async -> ServiceResponse
private let maxBodyBytes = 1_048_576

// Serves HTTP/1.1 on loopback until the process exits. NIO parses requests, answers
// malformed ones with 400, and handles keep-alive and pipelining.
private func listen(port: UInt16, responder: @escaping Responder) async throws {
  let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    // A client may half-close after sending; keep writing its responses.
    .childChannelOption(.allowRemoteHalfClosure, value: true)
    .bind(host: "127.0.0.1", port: Int(port)) { channel in
      channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
        return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
          wrappingChannelSynchronously: channel)
      }
    }
  serverLogger.info("Server started and listening on 127.0.0.1:\(port)")
  try await withThrowingDiscardingTaskGroup { group in
    try await server.executeThenClose { connections in
      for try await connection in connections {
        group.addTask { await serveConnection(connection, responder: responder) }
      }
    }
  }
}

private func serveConnection(
  _ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
  responder: Responder
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
          CollectedRequest(head: request, body: oversized ? nil : Data(body.readableBytesView)))
        var headers = HTTPHeaders([("Content-Type", response.type)])
        for (name, value) in response.headers { headers.replaceOrAdd(name: name, value: value) }
        if response.status != 204 {
          headers.add(name: "Content-Length", value: String(response.body.count))
        }
        headers.add(name: "Date", value: Date().formatted(httpDate))
        try await outbound.write(
          .head(
            HTTPResponseHead(
              version: .http1_1, status: .init(statusCode: response.status), headers: headers)))
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
