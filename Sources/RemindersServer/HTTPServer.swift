import Foundation
import GraphQL
import Hummingbird

struct ServiceResponse {
  var status: Int = 200
  var type = "application/json"
  var body: Data
  var headers: [String: String] = [:]
  static func json(_ object: Any, status: Int = 200) throws -> ServiceResponse {
    ServiceResponse(
      status: status,
      body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
  }
}
func handleRequest(
  method: String, path: String, body: Data, schema: GraphQLSchema,
  metricsCollector: MetricsCollector
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
  guard path == "/graphql" || path == "/mcp" else {
    return try .json(["error": "Not found"], status: 404)
  }
  guard method == "POST" else { return try .json(["error": "POST required"], status: 405) }
  guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
    return try .json(
      [
        "jsonrpc": "2.0", "id": NSNull(),
        "error": ["code": -32700, "message": "Expected one JSON object"],
      ], status: 400)
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
    let result = try await graphql(
      schema: schema, request: query, context: GraphQLContext(), variableValues: variables,
      operationName: operation)
    return ServiceResponse(body: try GraphQLJSONEncoder().encode(result))
  } catch { return try .json(["errors": [["message": String(describing: error)]]]) }
}

func serve(port: UInt16, metricsInterval: Int) async throws {
  let metricsCollector = MetricsCollector()
  let collectionTask = Task { await metricsCollector.run(intervalSeconds: metricsInterval) }
  defer { collectionTask.cancel() }
  let schema = try makeSchema()
  let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
  let responder = CallbackResponder<BasicRequestContext> { request, _ in
    let response: ServiceResponse
    var headers: [String: String] = [:]
    // Reject ambiguous repeated headers instead of silently picking one.
    for header in request.headers {
      let key = header.name.rawName.lowercased()
      guard headers[key] == nil else { return Response(status: .badRequest) }
      headers[key] = header.value
    }
    headers["host"] = request.head.authority ?? headers["host"]
    if !hosts.contains(headers["host"] ?? "")
      || (headers["origin"] != nil && !hosts.map({ "http://" + $0 }).contains(headers["origin"]!))
    {
      response = try .json(["error": "Untrusted host or origin"], status: 403)
    } else if request.method == .post
      && headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        .lowercased() != "application/json"
    {
      response = try .json(["error": "Content-Type application/json required"], status: 415)
    } else {
      let body: Data
      do { body = Data(try await request.body.collect(upTo: 1_048_576).readableBytesView) } catch {
        return Response(status: .contentTooLarge)
      }
      if request.uri.path == "/mcp" {
        response = try await handleMCP(
          method: request.method.rawValue, headers: headers, body: body)
      } else {
        response = try await handleRequest(
          method: request.method.rawValue, path: request.uri.path, body: body, schema: schema,
          metricsCollector: metricsCollector)
      }
    }
    var fields: HTTPFields = [.contentType: response.type]
    for (name, value) in response.headers {
      fields[.init(name)!] = value
    }
    return Response(
      status: .init(code: response.status), headers: fields,
      body: .init(byteBuffer: ByteBuffer(bytes: response.body)))
  }
  let app = Application(
    responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: Int(port))))
  try await app.runService()
}
