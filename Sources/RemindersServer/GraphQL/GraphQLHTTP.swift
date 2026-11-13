import Foundation
import GraphQL
import NIOHTTP1

// Serves POST /graphql. The schema is built once and shared by every request.
func makeGraphQLHandler() throws -> APIHandler {
  let schema = try makeSchema()
  return { method, headers, body, access in
    try await handleGraphQL(
      method: method, accept: headers["accept"], body: body, schema: schema, access: access)
  }
}

func graphQLSchemaSDL() throws -> String { printSchema(schema: try makeSchema()) }

private enum GraphQLMediaType {
  case graphQLResponse
  case legacyJSON

  init?(accept: String?) {
    var qualities: [String: Double] = [:]
    for range in (accept ?? "*/*").split(separator: ",") {
      let parts = range.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
      let q = parts.dropFirst().first { $0.hasPrefix("q=") }.map { Double($0.dropFirst(2)) ?? 0 }
      qualities[parts.first?.lowercased() ?? ""] = q ?? 1
    }
    func quality(_ type: String) -> Double {
      [type, "application/*", "*/*"].lazy.compactMap { qualities[$0] }.first ?? 0
    }
    let response = quality(Self.graphQLResponseType)
    let json = quality("application/json")
    guard max(response, json) > 0 else { return nil }
    self = response >= json ? .graphQLResponse : .legacyJSON
  }

  static let graphQLResponseType = "application/graphql-response+json"

  func contentType(_ status: HTTPResponseStatus) -> String {
    self == .legacyJSON && (200..<300).contains(status.code)
      ? "application/json" : Self.graphQLResponseType + "; charset=utf-8"
  }
}

private func handleGraphQL(
  method: HTTPMethod, accept: String?, body: Data, schema: GraphQLSchema,
  access: Capabilities.Access
) async throws -> ServiceResponse {
  guard method == .POST else {
    var response = ServiceResponse.error("POST required", status: .methodNotAllowed)
    response.headers.add(name: "Allow", value: "POST")
    return response
  }
  guard let mediaType = GraphQLMediaType(accept: accept) else {
    return .error(
      "Accept must allow \(GraphQLMediaType.graphQLResponseType) or application/json",
      status: .notAcceptable)
  }
  func respond(_ result: GraphQLResult, status: HTTPResponseStatus = .ok) throws
    -> ServiceResponse
  {
    var response = ServiceResponse(
      status: status, body: try GraphQLJSONEncoder().encode(result),
      failure: result.errors.isEmpty ? nil : .graphql)
    response.headers.replaceOrAdd(name: "Content-Type", value: mediaType.contentType(status))
    return response
  }
  func reject(_ message: String, status: HTTPResponseStatus) throws -> ServiceResponse {
    try respond(GraphQLResult(errors: [GraphQLError(message: message)]), status: status)
  }

  let request: GraphQLRequest
  do { request = try JSONDecoder().decode(GraphQLRequest.self, from: body) } catch {
    if case .dataCorrupted(let context) = error as? DecodingError, context.codingPath.isEmpty {
      return try reject("Request body must be JSON", status: .badRequest)
    }
    let message = (error as? DecodingError).map(inputMessage) ?? "Expected one JSON object"
    return try reject(message, status: .unprocessableEntity)
  }
  let document: Document
  do {
    document = try parse(source: Source(body: request.query, name: "GraphQL request"))
  } catch let error as GraphQLError {
    return try respond(GraphQLResult(errors: [error]), status: .badRequest)
  }
  let invalid = validate(schema: schema, ast: document)
  guard invalid.isEmpty else {
    return try respond(GraphQLResult(errors: invalid), status: .unprocessableEntity)
  }
  let selected = document.definitions.compactMap { $0 as? OperationDefinition }.filter {
    request.operationName == nil || $0.name?.value == request.operationName
  }
  guard selected.count == 1 else {
    return try reject(
      "Select exactly one operation with operationName", status: .unprocessableEntity)
  }
  if access != .write && selected[0].operation != .query {
    return try reject("Forbidden: GraphQL write access required", status: .forbidden)
  }

  var result = try await execute(
    schema: schema, documentAST: document, rootValue: (), context: GraphQLContext(),
    variableValues: request.variables, operationName: request.operationName)
  result.errors = result.errors.map(withErrorCode)
  // GraphQLSwift also drops data when a non-null root field fails.
  if result.data == nil {
    guard result.errors.contains(where: { !$0.path.elements.isEmpty }) else {
      return try respond(result, status: .unprocessableEntity)
    }
    result.data = .null
  }
  return try respond(result)
}

// The executor wraps resolver errors; put the server's code where GraphQL clients expect it.
private func withErrorCode(_ error: GraphQLError) -> GraphQLError {
  guard let server = error.originalError as? ServerError else { return error }
  return GraphQLError(
    message: error.message, locations: error.locations, path: error.path,
    extensions: error.extensions.merging(["code": .string(server.code.rawValue)]) { _, new in new })
}
