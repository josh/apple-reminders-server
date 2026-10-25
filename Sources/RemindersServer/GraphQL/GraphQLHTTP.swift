import Foundation
import GraphQL

// Serves POST /graphql. The schema is built once and shared by every request.
func makeGraphQLHandler() throws -> APIHandler {
  let schema = try makeSchema()
  return { method, _, body, access in
    try await handleGraphQL(method: method, body: body, schema: schema, access: access)
  }
}

func graphQLSchemaSDL() throws -> String { printSchema(schema: try makeSchema()) }

private func handleGraphQL(
  method: String, body: Data, schema: GraphQLSchema, access: Capabilities.Access
) async throws -> ServiceResponse {
  guard method == "POST" else { return try .json(["error": "POST required"], status: 405) }
  let request: GraphQLRequest
  do { request = try JSONDecoder().decode(GraphQLRequest.self, from: body) } catch {
    let message = (error as? GraphQLRequest.Invalid)?.message ?? "Expected one JSON object"
    return try .json(["errors": [["message": message]]], status: 400)
  }
  let query = request.query
  let variables = request.variables
  let operation = request.operationName
  do {
    if access != .write {
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
      failure: result.errors.isEmpty ? nil : "graphql")
  } catch { return try .json(["errors": [graphQLError(error)]], failure: "graphql") }
}

// The POST body. Null variables or operationName mean absent.
private struct GraphQLRequest: Decodable {
  struct Invalid: Error { let message: String }
  let query: String
  let variables: [String: Map]
  let operationName: String?
  enum CodingKeys: String, CodingKey { case query, variables, operationName }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard let query = try? c.decode(String.self, forKey: .query) else {
      throw Invalid(message: "query must be a string")
    }
    self.query = query
    do { variables = try c.decodeIfPresent([String: Map].self, forKey: .variables) ?? [:] } catch {
      throw Invalid(message: "variables must be an object")
    }
    do { operationName = try c.decodeIfPresent(String.self, forKey: .operationName) } catch {
      throw Invalid(message: "operationName must be a string")
    }
  }
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
