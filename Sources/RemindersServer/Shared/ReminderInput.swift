import Foundation

// Reminder create and patch input. Creation and patches accept different fields.
struct ReminderInput: Decodable, Sendable {
  let listId, name, body, location, url: InputField<String>
  let dueDate, allDayDueDate, startDate, allDayStartDate: InputField<String>
  let timeZone, remindMeDate, completionDate: InputField<String>
  let priority: InputField<Int>
  let flagged, completed: InputField<Bool>
  let alarms: InputField<[AlarmInput]>
  let recurrence: InputField<RecurrenceInput>
  let clearFields: InputField<[String]>
  let containsNull: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case listId, name, body, location, url, dueDate, allDayDueDate, startDate, allDayStartDate
    case timeZone, remindMeDate, completionDate, priority, flagged, completed, alarms
    case recurrence, clearFields
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    listId = try c.field(.listId)
    name = try c.field(.name)
    body = try c.field(.body)
    location = try c.field(.location)
    url = try c.field(.url)
    dueDate = try c.field(.dueDate)
    allDayDueDate = try c.field(.allDayDueDate)
    startDate = try c.field(.startDate)
    allDayStartDate = try c.field(.allDayStartDate)
    timeZone = try c.field(.timeZone)
    remindMeDate = try c.field(.remindMeDate)
    completionDate = try c.field(.completionDate)
    priority = try c.field(.priority)
    flagged = try c.field(.flagged)
    completed = try c.field(.completed)
    alarms = try c.field(.alarms)
    recurrence = try c.field(.recurrence)
    clearFields = try c.field(.clearFields)
    containsNull = try c.containsNull()
  }
}

struct AlarmInput: Decodable, Sendable {
  let absoluteDate: InputField<String>
  let relativeOffsetSeconds: InputField<Double>
  let geofence: InputField<GeofenceInput>

  enum CodingKeys: String, CodingKey, CaseIterable {
    case absoluteDate, relativeOffsetSeconds, geofence
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    absoluteDate = try c.field(.absoluteDate)
    relativeOffsetSeconds = try c.field(.relativeOffsetSeconds)
    geofence = try c.field(.geofence)
  }
}

struct GeofenceInput: Decodable, Sendable {
  let title: InputField<String>
  let latitude, longitude, radiusMeters: Double
  let proximity: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case title, latitude, longitude, radiusMeters, proximity
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    title = try c.field(.title)
    latitude = try c.decode(Double.self, forKey: .latitude)
    longitude = try c.decode(Double.self, forKey: .longitude)
    radiusMeters = try c.decode(Double.self, forKey: .radiusMeters)
    proximity = try c.decode(String.self, forKey: .proximity)
  }
}

func reminderChanges(_ input: ReminderInput, creating: Bool) throws -> ReminderChanges {
  let patchOnly = [
    input.completed.isAbsent, input.completionDate.isAbsent, input.clearFields.isAbsent,
  ]
  guard creating ? !patchOnly.contains(false) : input.listId.isAbsent else {
    throw ServerError.invalidArgument("Unknown input field")
  }
  if !creating, input.containsNull {
    throw ServerError.invalidArgument("patch values cannot be null; use clearFields")
  }
  var result = ReminderChanges()
  result.name = input.name.value
  result.body = input.body.value
  // Reminders drops free-text locations on save; reject them rather than lose data silently.
  let noLocation = "Reminders does not keep free-text locations; use a geofence alarm instead"
  if input.location.value != nil { throw ServerError.unsupportedOperation(noLocation) }
  if let value = input.url.value {
    guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty,
      value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw ServerError.invalidArgument("url must be an absolute URL without whitespace")
    }
    result.url = url
  }
  result.priority = input.priority.value
  result.completed = input.completed.value
  if let names = input.clearFields.value {
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
  if result.clear.contains(.location) { throw ServerError.unsupportedOperation(noLocation) }
  func date(
    _ timed: String?, _ day: String?, _ timedClear: ReminderClearValue,
    _ dayClear: ReminderClearValue
  ) throws -> DateComponents? {
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
  if input.allDayStartDate.value != nil {
    throw ServerError.unsupportedOperation(
      "this Reminders provider normalizes date-only starts to timed midnight; use startDate explicitly"
    )
  }
  if let completion = input.completionDate.value {
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
  result.alarms = try input.alarms.value?.map(alarmChange)
  if let recurrence = input.recurrence.value {
    guard !result.clear.contains(.recurrence) else {
      throw ServerError.invalidArgument("cannot set and clear recurrence")
    }
    result.recurrence = try recurrenceChange(recurrence)
  }
  result.flagged = input.flagged.value
  if let alert = input.remindMeDate.value {
    result.remindMeDate = try parseTimestamp(alert)
  }
  if let zone = input.timeZone.value {
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
  result.due = try date(input.dueDate.value, input.allDayDueDate.value, .dueDate, .allDayDueDate)
  result.start = try date(
    input.startDate.value, input.allDayStartDate.value, .startDate, .allDayStartDate)
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
  guard !(result.url != nil && result.clear.contains(.url)) else {
    throw ServerError.invalidArgument("cannot set and clear the same field")
  }
  guard creating || result != ReminderChanges() else {
    throw ServerError.invalidArgument("patch must contain at least one change")
  }
  return result
}

func alarmChange(_ input: AlarmInput) throws -> ReminderAlarmChange {
  switch (input.absoluteDate.value, input.relativeOffsetSeconds.value, input.geofence.value) {
  case (let date?, nil, nil):
    return .absolute(try parseTimestamp(date))
  case (nil, let offset?, nil):
    guard offset.isFinite else {
      throw ServerError.invalidArgument("alarm offset must be finite")
    }
    return .relative(offset)
  case (nil, nil, let geo?):
    guard geo.latitude.isFinite, geo.longitude.isFinite, geo.radiusMeters.isFinite,
      (-90...90).contains(geo.latitude), (-180...180).contains(geo.longitude),
      geo.radiusMeters >= 0, ["ARRIVE", "DEPART"].contains(geo.proximity)
    else { throw ServerError.invalidArgument("invalid geofence") }
    return .location(
      title: geo.title.value, latitude: geo.latitude, longitude: geo.longitude,
      radius: geo.radiusMeters, arriving: geo.proximity == "ARRIVE")
  default:
    throw ServerError.invalidArgument("each alarm requires exactly one trigger")
  }
}
