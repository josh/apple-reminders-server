import Foundation
import GraphQL
import NIOHTTP1

// Serves POST /graphql. The schema is built once and shared by every request.
func makeGraphQLHandler() throws -> APIHandler {
  let schema = try makeSchema()
  return { method, _, body, access in
    try await handleGraphQL(method: method, body: body, schema: schema, access: access)
  }
}

func graphQLSchemaSDL() throws -> String { printSchema(schema: try makeSchema()) }

private func handleGraphQL(
  method: HTTPMethod, body: Data, schema: GraphQLSchema, access: Capabilities.Access
) async throws -> ServiceResponse {
  guard method == .POST else { return .error("POST required", status: .methodNotAllowed) }
  let request: GraphQLRequest
  do { request = try JSONDecoder().decode(GraphQLRequest.self, from: body) } catch {
    let message = (error as? DecodingError).map(inputMessage) ?? "Expected one JSON object"
    return .json(GraphQLErrors(message), status: .badRequest)
  }
  do {
    if access != .write {
      let document = try parse(source: request.query)
      let operations = document.definitions.compactMap { $0 as? OperationDefinition }
      let selected = operations.filter {
        request.operationName == nil || $0.name?.value == request.operationName
      }
      guard selected.count == 1 else {
        return .json(
          GraphQLErrors("Select exactly one operation with operationName"), status: .badRequest)
      }
      guard selected[0].operation == .query else {
        return .json(GraphQLErrors("Forbidden: GraphQL write access required"), status: .forbidden)
      }
    }
    var result = try await graphql(
      schema: schema, request: request.query, context: GraphQLContext(),
      variableValues: request.variables, operationName: request.operationName)
    result.errors = result.errors.map(withErrorCode)
    return ServiceResponse(
      body: try GraphQLJSONEncoder().encode(result),
      failure: result.errors.isEmpty ? nil : .graphql)
  } catch { return .json(GraphQLErrors(error), failure: .graphql) }
}

// The executor wraps resolver errors; put the server's code where GraphQL clients expect it.
private func withErrorCode(_ error: GraphQLError) -> GraphQLError {
  guard let server = error.originalError as? ServerError else { return error }
  return GraphQLError(
    message: error.message, locations: error.locations, path: error.path,
    extensions: error.extensions.merging(["code": .string(server.code.rawValue)]) { _, new in new })
}
// A request-level GraphQL error response, for failures before or outside execution.
private struct GraphQLErrors: Encodable {
  struct Entry: Encodable {
    struct Extensions: Encodable { let code: String }
    let message: String
    let extensions: Extensions?
  }
  let errors: [Entry]
  init(_ message: String) { errors = [Entry(message: message, extensions: nil)] }
  init(_ error: Error) {
    let server = error as? ServerError
    errors = [
      Entry(
        message: server?.message ?? String(describing: error),
        extensions: server.map { Entry.Extensions(code: $0.code.rawValue) })
    ]
  }
}
