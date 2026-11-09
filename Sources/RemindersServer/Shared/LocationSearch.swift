import Foundation
import MapKit

struct LocationSearchArguments: Decodable, Sendable {
  let query: String
  let limit: Int
  enum CodingKeys: String, CodingKey, CaseIterable { case query, limit }

  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    query = try c.decode(String.self, forKey: .query)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 5
    guard !query.isEmpty else { throw ServerError.invalidArgument("query must not be blank") }
    guard (1...10).contains(limit) else {
      throw ServerError.invalidArgument("limit must be 1...10")
    }
  }
}

struct LocationSearchResult: Encodable, Sendable {
  let name: String?
  let address: String?
  let latitude: Double
  let longitude: Double
  enum CodingKeys: String, CodingKey { case name, address, latitude, longitude }

  init(_ item: MKMapItem) throws {
    let coordinate = item.placemark.coordinate
    guard CLLocationCoordinate2DIsValid(coordinate) else {
      throw ServerError.internalError("Location search returned invalid coordinates")
    }
    name = item.name
    address = item.placemark.title
    latitude = coordinate.latitude
    longitude = coordinate.longitude
  }
}

// Search only: callers choose a candidate before creating an alarm with its coordinates.
@MainActor
func searchLocations(_ input: LocationSearchArguments) async throws -> [LocationSearchResult] {
  try Task.checkCancellation()
  let request = MKLocalSearch.Request()
  request.naturalLanguageQuery = input.query
  request.resultTypes = [.address, .pointOfInterest]
  let search = MKLocalSearch(request: request)
  var timedOut = false
  let timeout = Task {
    try await Task.sleep(for: .seconds(30))
    timedOut = true
    search.cancel()
  }
  defer { timeout.cancel() }
  let response: MKLocalSearch.Response
  do {
    response = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await search.start()
    } onCancel: {
      Task { @MainActor in search.cancel() }
    }
    try Task.checkCancellation()
  } catch {
    if Task.isCancelled { throw CancellationError() }
    if timedOut {
      throw ServerError.internalError("Location search timed out after 30 seconds")
    }
    throw ServerError.internalError(
      "Location search failed (code \((error as NSError).code)): \(error.localizedDescription)")
  }
  return try response.mapItems.prefix(input.limit).map(LocationSearchResult.init)
}
