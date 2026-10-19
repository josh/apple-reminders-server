import Foundation

// Transport-neutral JSON input. Both HTTP APIs validate the same changes before
// invoking the typed mutation entrypoint.
indirect enum MutationInput: Decodable, Equatable, Sendable {
  case undefined, null
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case array([MutationInput])
  case object([String: MutationInput])
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Int.self) {
      self = .int(v)
    } else if let v = try? c.decode(Double.self) {
      self = .double(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([MutationInput].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: MutationInput].self))
    }
  }
  subscript(_ key: String) -> MutationInput {
    if case .object(let v) = self { return v[key] ?? .undefined }
    return .undefined
  }
  func stringValue() throws -> String {
    guard case .string(let v) = self else { throw invalid("Expected a string") }
    return v
  }
  func intValue() throws -> Int {
    guard case .int(let v) = self else { throw invalid("Expected an integer") }
    return v
  }
  func boolValue() throws -> Bool {
    guard case .bool(let v) = self else { throw invalid("Expected a boolean") }
    return v
  }
  func doubleValue() throws -> Double {
    switch self {
    case .double(let v): return v
    case .int(let v): return Double(v)
    default: throw invalid("Expected a number")
    }
  }
  func arrayValue() throws -> [MutationInput] {
    guard case .array(let v) = self else { throw invalid("Expected an array") }
    return v
  }
  func dictionaryValue() throws -> [String: MutationInput] {
    guard case .object(let v) = self else { throw invalid("Expected an object") }
    return v
  }
  func checkKeys(_ allowed: Set<String>) throws {
    guard try Set(dictionaryValue().keys).isSubset(of: allowed) else {
      throw invalid("Unknown input field")
    }
  }
  func rejectNulls() throws {
    switch self {
    case .null: throw invalid("Omit optional MCP inputs instead of sending null")
    case .object(let v):
      for value in v.values { try value.rejectNulls() }
    case .array(let v):
      for value in v { try value.rejectNulls() }
    default: break
    }
  }
  private func invalid(_ text: String) -> ServerError { .invalidArgument(text) }
}
func mutationInput<T: Encodable>(_ value: T) throws -> MutationInput {
  try JSONDecoder().decode(MutationInput.self, from: JSONEncoder().encode(value))
}

func reminderChanges(_ input: MutationInput, creating: Bool) throws -> ReminderChanges {
  let common: Set<String> = [
    "name", "body", "priority", "location", "url", "dueDate", "allDayDueDate", "startDate",
    "allDayStartDate", "alarms", "recurrence", "timeZone", "flagged", "remindMeDate",
  ]
  try input.checkKeys(
    common.union(creating ? ["listId"] : ["completed", "completionDate", "clearFields"]))
  let values = try input.dictionaryValue()
  if !creating, values.values.contains(.null) {
    throw ServerError.invalidArgument("patch values cannot be null; use clearFields")
  }
  func text(_ key: String) throws -> String? {
    let value = input[key]
    if value == .undefined || value == .null { return nil }
    return try value.stringValue()
  }
  var result = ReminderChanges()
  result.name = try text("name")
  result.body = try text("body")
  result.location = try text("location")
  if let value = try text("url") {
    guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty,
      value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw ServerError.invalidArgument("url must be an absolute URL without whitespace")
    }
    result.url = url
  }
  if input["priority"] != .undefined && input["priority"] != .null {
    result.priority = try input["priority"].intValue()
  }
  if input["completed"] != .undefined && input["completed"] != .null {
    result.completed = try input["completed"].boolValue()
  }
  let rawClear = input["clearFields"]
  if rawClear != .undefined && rawClear != .null {
    let names = try rawClear.arrayValue().map { try $0.stringValue() }
    guard Set(names).count == names.count else {
      throw ServerError.invalidArgument("duplicate clearFields")
    }
    result.clear = try Set(
      names.map {
        guard let value = ReminderClearValue(rawValue: $0) else {
          throw ServerError.unsupportedOperation("unsupported clear field")
        }
        return value
      })
  }
  func date(
    _ timedKey: String, _ dayKey: String, _ timedClear: ReminderClearValue,
    _ dayClear: ReminderClearValue
  ) throws -> DateComponents? {
    let timed = try text(timedKey)
    let day = try text(dayKey)
    let clear = result.clear.contains(timedClear) || result.clear.contains(dayClear)
    guard !(timed != nil && day != nil), !(clear && (timed != nil || day != nil)),
      !(result.clear.contains(timedClear) && result.clear.contains(dayClear))
    else {
      throw ServerError.invalidArgument("conflicting date representations or clearFields")
    }
    if let timed {
      let instant = try parseTimestamp(timed)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(secondsFromGMT: 0)!
      var parts = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: instant)
      parts.calendar = calendar
      parts.timeZone = calendar.timeZone
      return parts
    }
    if let day {
      try validateDays(day, nil)
      let values = day.split(separator: "-").map { Int($0)! }
      var parts = DateComponents(year: values[0], month: values[1], day: values[2])
      parts.calendar = Calendar(identifier: .gregorian)
      return parts
    }
    return nil
  }
  if try text("allDayStartDate") != nil {
    throw ServerError.unsupportedOperation(
      "this Reminders provider normalizes date-only starts to timed midnight; use startDate explicitly"
    )
  }
  if let completion = try text("completionDate") {
    result.completionDate = try parseTimestamp(completion)
  }
  guard
    !(result.completed != nil
      && (result.completionDate != nil || result.clear.contains(.completionDate))),
    !(result.completionDate != nil && result.clear.contains(.completionDate))
  else {
    throw ServerError.invalidArgument(
      "completed and completionDate changes are mutually exclusive")
  }
  if input["alarms"] != .undefined && input["alarms"] != .null {
    result.alarms = try input["alarms"].arrayValue().map(parseAlarmInput)
  }
  if input["recurrence"] != .undefined && input["recurrence"] != .null {
    guard !result.clear.contains(.recurrence) else {
      throw ServerError.invalidArgument("cannot set and clear recurrence")
    }
    result.recurrence = try parseRecurrenceInput(input["recurrence"])
  }
  if input["flagged"] != .undefined && input["flagged"] != .null {
    result.flagged = try input["flagged"].boolValue()
  }
  if let alert = try text("remindMeDate") { result.remindMeDate = try parseTimestamp(alert) }
  if let zone = try text("timeZone") {
    guard TimeZone.knownTimeZoneIdentifiers.contains(zone) || zone == "UTC",
      let parsed = TimeZone(identifier: zone)
    else {
      throw ServerError.invalidArgument("timeZone must be an IANA time-zone identifier")
    }
    result.timeZone = parsed
  }
  guard !(result.timeZone != nil && result.clear.contains(.timeZone)),
    !(result.alarms != nil && result.remindMeDate != nil)
  else {
    throw ServerError.invalidArgument(
      "conflicting timeZone, remindMeDate, alarms or clearFields")
  }
  result.due = try date("dueDate", "allDayDueDate", .dueDate, .allDayDueDate)
  result.start = try date("startDate", "allDayStartDate", .startDate, .allDayStartDate)
  if result.remindMeDate != nil {
    let dateClears: Set<ReminderClearValue> = [
      .dueDate, .allDayDueDate, .startDate, .allDayStartDate, .timeZone,
    ]
    guard
      result.due == nil && result.start == nil && result.timeZone == nil
        && result.clear.isDisjoint(with: dateClears)
    else {
      throw ServerError.invalidArgument(
        "remindMeDate changes stored date components; do not combine it with start, due or timeZone changes"
      )
    }
  }
  guard !(result.location != nil && result.clear.contains(.location)),
    !(result.url != nil && result.clear.contains(.url))
  else {
    throw ServerError.invalidArgument("cannot set and clear the same field")
  }
  guard creating || result != ReminderChanges() else {
    throw ServerError.invalidArgument("patch must contain at least one change")
  }
  return result
}

func parseAlarmInput(_ input: MutationInput) throws -> ReminderAlarmChange {
  try input.checkKeys(["absoluteDate", "relativeOffsetSeconds", "geofence"])
  let keys = ["absoluteDate", "relativeOffsetSeconds", "geofence"].filter {
    input[$0] != .null && input[$0] != .undefined
  }
  guard keys.count == 1 else {
    throw ServerError.invalidArgument("each alarm requires exactly one trigger")
  }
  if keys[0] == "absoluteDate" {
    return .absolute(try parseTimestamp(input["absoluteDate"].stringValue()))
  }
  if keys[0] == "relativeOffsetSeconds" {
    let offset = try input["relativeOffsetSeconds"].doubleValue()
    guard offset.isFinite else {
      throw ServerError.invalidArgument("alarm offset must be finite")
    }
    return .relative(offset)
  }
  let geo = input["geofence"]
  try geo.checkKeys(["title", "latitude", "longitude", "radiusMeters", "proximity"])
  let latitude = try geo["latitude"].doubleValue()
  let longitude = try geo["longitude"].doubleValue()
  let radius = try geo["radiusMeters"].doubleValue()
  let proximity = try geo["proximity"].stringValue()
  guard latitude.isFinite, longitude.isFinite, radius.isFinite, (-90...90).contains(latitude),
    (-180...180).contains(longitude), radius >= 0,
    ["ARRIVE", "DEPART"].contains(proximity)
  else { throw ServerError.invalidArgument("invalid geofence") }
  let title =
    geo["title"] == .undefined || geo["title"] == .null ? nil : try geo["title"].stringValue()
  return .location(
    title: title, latitude: latitude, longitude: longitude, radius: radius,
    arriving: proximity == "ARRIVE")
}
