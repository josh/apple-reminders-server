import Foundation
import GraphQL
import HTTPTypes
import Hummingbird
import Logging
struct ServiceResponse {
  var status: Int = 200
  var type = "application/json"
  var body: Data
  var headers: [String: String] = [:]
  // The handler that knows the outcome sets failure; unclassified bodies are inspected.
  var failure: String? = nil
  var classified = false
  static func json(_ object: Any, status: Int = 200, failure: String? = nil) throws
    -> ServiceResponse
  {
    ServiceResponse(
      status: status,
      body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      failure: failure, classified: true)
  }
}
func handleRequest(
  method: String, path: String, body: Data, schema: GraphQLSchema,
  metricsCollector: MetricsCollector, capabilities: Capabilities
) async throws
  -> ServiceResponse
{
  if path == "/metrics" && method == "GET" {
    do {
      return ServiceResponse(
        type: "text/plain; version=0.0.4; charset=utf-8",
        body: Data(try await metricsCollector.cachedSnapshot().utf8))
    } catch { return try .json(["error": String(describing: error)], status: 503) }
  }
  guard path == "/graphql" else { return try .json(["error": "Not found"], status: 404) }
  guard method == "POST" else { return try .json(["error": "POST required"], status: 405) }
  guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
    return try .json(["errors": [["message": "Expected one JSON object"]]], status: 400)
  }
  guard let query = request["query"] as? String else {
    return try .json(["errors": [["message": "query must be a string"]]], status: 400)
  }
  if let variables = request["variables"], !(variables is NSNull), !(variables is [String: Any]) {
    return try .json(["errors": [["message": "variables must be an object"]]], status: 400)
  }
  if let operation = request["operationName"], !(operation is NSNull), !(operation is String) {
    return try .json(["errors": [["message": "operationName must be a string"]]], status: 400)
  }
  let variables = try JSONDecoder().decode(
    [String: Map].self,
    from: JSONSerialization.data(withJSONObject: request["variables"] as? [String: Any] ?? [:]))
  let operation = request["operationName"] as? String
  do {
    if capabilities.graphql != .write {
      let document = try parse(source: query)
      let operations = document.definitions.compactMap { $0 as? OperationDefinition }
      let selected = operations.filter { operation == nil || $0.name?.value == operation }
      guard selected.count == 1 else {
        return try .json(
          ["errors": [["message": "Select exactly one operation with operationName"]]], status: 400)
      }
      guard selected[0].operation == .query else {
        return try .json(
          ["errors": [["message": "Forbidden: GraphQL write access required"]]], status: 403)
      }
    }
    var result = try await graphql(
      schema: schema, request: query, context: GraphQLContext(), variableValues: variables,
      operationName: operation)
    result.errors = result.errors.map(withErrorCode)
    return ServiceResponse(
      body: try GraphQLJSONEncoder().encode(result),
      failure: result.errors.isEmpty ? nil : "graphql", classified: true)
  } catch { return try .json(["errors": [graphQLError(error)]], failure: "graphql") }
}

// The executor wraps resolver errors; put the server's code where GraphQL clients expect it.
private func withErrorCode(_ error: GraphQLError) -> GraphQLError {
  guard let server = error.originalError as? ServerError else { return error }
  return GraphQLError(
    message: error.message, locations: error.locations, path: error.path,
    extensions: error.extensions.merging(["code": .string(server.code.rawValue)]) { _, new in new })
}
private func graphQLError(_ error: Error) -> [String: Any] {
  guard let server = error as? ServerError else { return ["message": String(describing: error)] }
  return ["message": server.message, "extensions": ["code": server.code.rawValue]]
}

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
private func jsonRPCMethod(_ body: Data) -> String {
  let object = try? JSONSerialization.jsonObject(with: body)
  if let method = (object as? [String: Any])?["method"] as? String { return method }
  return object is [Any] ? "batch" : "unknown"
}

private let requestDeadline: Duration = .seconds(60)
private struct RequestTimedOut: Error {}
private func withRequestDeadline<T: Sendable>(
  _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: requestDeadline)
      throw RequestTimedOut()
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw RequestTimedOut() }
    return result
  }
}

func serve(
  port: UInt16, metricsInterval: Int, allowedOrigins: [String], tailscaleAppCapability: String?
) async throws {
  let metricsCollector = MetricsCollector()
  let collectionTask = Task { await metricsCollector.run(intervalSeconds: metricsInterval) }
  defer { collectionTask.cancel() }
  let schema = try makeSchema()
  let origins = Set(["http://127.0.0.1:\(port)", "http://localhost:\(port)"] + allowedOrigins)
  let responder = CallbackResponder<BasicRequestContext> { request, _ in
    let started = ContinuousClock.now
    var rpc: String?
    func respond(_ response: ServiceResponse) -> Response {
      let elapsed = started.duration(to: .now).components
      let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
      let route =
        ["/graphql", "/mcp", "/metrics"].contains(request.uri.path)
        ? request.uri.path : "other"
      // MCP clients probe for an event stream with GET; the spec answer is 405.
      let probe = request.method == .get && route == "/mcp" && response.status == 405
      let failure = probe ? nil : response.failureKind
      let level: Logger.Level =
        response.status >= 500 ? .error : failure == nil ? .debug : .notice
      var metadata: Logger.Metadata = [
        "method": "\(request.method.rawValue)", "route": "\(route)",
        "status": "\(response.status)", "duration_ms": "\(String(format: "%.2f", milliseconds))",
        "outcome": "\(failure ?? "ok")",
      ]
      // Tailscale serve forwards the peer address and, for user-owned nodes, the login.
      if let peer = request.headers[forwardedFor] { metadata["peer"] = "\(peer)" }
      if let login = request.headers[tailscaleUserLogin] { metadata["tailscale_user"] = "\(login)" }
      if let agent = request.headers[.userAgent] { metadata["user_agent"] = "\(agent)" }
      if let rpc { metadata["rpc"] = "\(rpc)" }
      serverLogger.log(level: level, "HTTP request", metadata: metadata)
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
          capabilities.allows(path: request.uri.path)
        else { return respond(try .json(["error": "Forbidden"], status: 403)) }
        let body: Data
        do { body = Data(try await request.body.collect(upTo: 1_048_576).readableBytesView) } catch
        {
          return respond(ServiceResponse(status: 413, body: Data()))
        }
        if request.uri.path == "/mcp" {
          if request.method == .post { rpc = jsonRPCMethod(body) }
          let requestHeaders = headers
          response = try await withRequestDeadline {
            try await handleMCP(
              method: request.method.rawValue, headers: requestHeaders, body: body,
              access: capabilities.mcp)
          }
        } else {
          response = try await withRequestDeadline {
            try await handleRequest(
              method: request.method.rawValue, path: request.uri.path, body: body, schema: schema,
              metricsCollector: metricsCollector, capabilities: capabilities)
          }
        }
      }
      return respond(response)
    } catch is RequestTimedOut {
      return respond(
        ServiceResponse(
          status: 504, body: Data(#"{"error":"Request timed out"}"#.utf8),
          failure: "timeout", classified: true))
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
