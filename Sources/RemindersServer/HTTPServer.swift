import Foundation
import HTTPTypes
import Hummingbird
import Logging

import struct os.OSAllocatedUnfairLock

struct ServiceResponse {
  var status: Int = 200
  var type = "application/json"
  var body: Data
  var headers: [String: String] = [:]
  // Set by the handler that knows the outcome of a successful HTTP response.
  var failure: String? = nil
  // Extra request details the handler wants logged.
  var logMetadata: [String: String] = [:]
  static func json(_ object: Any, status: Int = 200, failure: String? = nil) throws
    -> ServiceResponse
  {
    ServiceResponse(
      status: status,
      body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      failure: failure)
  }
}
// The served endpoints; any other path is logged and counted as "other".
enum Route: String {
  case graphql = "/graphql"
  case mcp = "/mcp"
  case metrics = "/metrics"
}

// One API endpoint: method, merged lowercase headers, body, and the caller's access.
typealias APIHandler =
  @Sendable (String, [String: String], Data, Capabilities.Access) async throws -> ServiceResponse

// Headers the server reads as one value; a repeat is ambiguous. Every other header
// may repeat per RFC 9110 and is joined with a comma, as proxies expect.
private let singleValueHeaders: Set<String> = [
  "origin", "content-type", "tailscale-app-capabilities",
]
private let proxyHeaders: Set<String> = [
  "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "forwarded",
  "tailscale-funnel-request",
]
private let forwardedFor = HTTPField.Name("x-forwarded-for")!
private let tailscaleUserLogin = HTTPField.Name("tailscale-user-login")!

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
  let responder = CallbackResponder<BasicRequestContext> { request, _ in
    let started = ContinuousClock.now
    let route = Route(rawValue: request.uri.path)
    func respond(_ response: ServiceResponse) -> Response {
      let elapsed = started.duration(to: .now).components
      let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
      let routeName = route?.rawValue ?? "other"
      // MCP clients probe for an event stream with GET; the spec answer is 405.
      let probe = request.method == .get && route == .mcp && response.status == 405
      let failure = probe ? nil : response.status >= 400 ? "http" : response.failure
      let level: Logger.Level =
        response.status >= 500 ? .error : failure == nil ? .debug : .notice
      var metadata: Logger.Metadata = [
        "method": "\(request.method.rawValue)", "route": "\(routeName)",
        "status": "\(response.status)", "duration_ms": "\(String(format: "%.2f", milliseconds))",
        "outcome": "\(failure ?? "ok")",
      ]
      // Tailscale serve forwards the peer address and, for user-owned nodes, the login.
      if let peer = request.headers[forwardedFor] { metadata["peer"] = "\(peer)" }
      if let login = request.headers[tailscaleUserLogin] { metadata["tailscale_user"] = "\(login)" }
      if let agent = request.headers[.userAgent] { metadata["user_agent"] = "\(agent)" }
      for (key, value) in response.logMetadata { metadata[key] = "\(value)" }
      serverLogger.log(level: level, "HTTP request", metadata: metadata)
      recordRequest(route: routeName, code: response.status)
      var fields: HTTPFields = [.contentType: response.type]
      for (name, value) in response.headers {
        fields[.init(name)!] = value
      }
      if let origin = request.headers[.origin], origins.contains(origin.lowercased()) {
        fields[.accessControlAllowOrigin] = origin
        fields[.vary] = "Origin"
      }
      return Response(
        status: .init(code: response.status), headers: fields,
        body: .init(byteBuffer: ByteBuffer(bytes: response.body)))
    }
    do {
      let response: ServiceResponse
      var headers: [String: String] = [:]
      for header in request.headers {
        let key = header.name.rawName.lowercased()
        guard let existing = headers[key] else {
          headers[key] = header.value
          continue
        }
        guard !singleValueHeaders.contains(key) else {
          return respond(try .json(["error": "Repeated \(key) header"], status: 400))
        }
        headers[key] = existing + ", " + header.value
      }
      if let origin = headers["origin"], !origins.contains(origin.lowercased()) {
        response = try .json(["error": "Untrusted origin"], status: 403)
      } else if request.method == .options {
        var preflightHeaders = ["Allow": "GET, POST, OPTIONS"]
        if headers["origin"] != nil {
          preflightHeaders["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
          preflightHeaders["Access-Control-Allow-Headers"] =
            headers["access-control-request-headers"]
            ?? "Content-Type, Accept, Mcp-Protocol-Version"
          preflightHeaders["Access-Control-Max-Age"] = "86400"
        }
        response = ServiceResponse(status: 204, body: Data(), headers: preflightHeaders)
      } else if request.method == .post
        && headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(
          in: .whitespaces
        )
        .lowercased() != "application/json"
      {
        response = try .json(["error": "Content-Type application/json required"], status: 415)
      } else {
        guard
          let capabilities = try? Capabilities.parse(
            header: headers["tailscale-app-capabilities"], capability: tailscaleAppCapability,
            proxied: headers.keys.contains(where: proxyHeaders.contains)),
          capabilities.allows(route)
        else { return respond(try .json(["error": "Forbidden"], status: 403)) }
        if route != .metrics && authorizing.withLock({ $0 }) {
          return respond(
            ServiceResponse(
              status: 503, body: Data(#"{"error":"Reminders authorization pending"}"#.utf8)))
        }
        let body: Data
        do { body = Data(try await request.body.collect(upTo: 1_048_576).readableBytesView) } catch
        {
          return respond(ServiceResponse(status: 413, body: Data()))
        }
        if route == .metrics && request.method == .get {
          let eventKit = await metricsCollector.cachedExposition()
          let runtime = runtimeMetrics(
            eventKitUp: eventKit != nil, authorizing: authorizing.withLock { $0 })
          response = ServiceResponse(
            type: "text/plain; version=0.0.4; charset=utf-8",
            body: Data((runtime + (eventKit ?? "")).utf8))
        } else if let route, let handler = handlers[route] {
          let method = request.method.rawValue
          let requestHeaders = headers
          let access = capabilities.access(route)
          response = try await withRequestDeadline {
            try await handler(method, requestHeaders, body, access)
          }
        } else {
          response = try .json(["error": "Not found"], status: 404)
        }
      }
      return respond(response)
    } catch is RequestTimedOut {
      return respond(
        ServiceResponse(status: 504, body: Data(#"{"error":"Request timed out"}"#.utf8)))
    } catch {
      logFailure("Request failed", error: error)
      return respond(
        ServiceResponse(status: 500, body: Data(#"{"error":"Internal server error"}"#.utf8)))
    }
  }
  let app = Application(
    responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: Int(port))),
    logger: serverLogger)
  try await app.runService()
}
