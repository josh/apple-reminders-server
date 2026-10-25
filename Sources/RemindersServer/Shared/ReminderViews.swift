import Foundation

struct RecurrenceView: Encodable {
  struct Day: Encodable {
    let day: Weekday
    let ordinal: Int?
    enum CodingKeys: String, CodingKey { case day, ordinal }
  }
  struct End: Encodable {
    let until: String?
    let count: Int?
    enum CodingKeys: String, CodingKey { case until, count }
  }
  let frequency: ScheduleFrequency
  let interval: Int
  let daysOfWeek: [Day]?
  let daysOfMonth: [Int]?, monthsOfYear: [Int]?, weeksOfYear: [Int]?, daysOfYear: [Int]?,
    setPositions: [Int]?
  let end: End?
  enum CodingKeys: String, CodingKey {
    case frequency, interval, daysOfWeek, daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear
    case setPositions, end
  }
  init(_ rule: RecurrenceRecord) throws {
    guard let frequency = ScheduleFrequency(rule.frequency) else {
      throw ServerError.unsupported("unknown recurrence frequency")
    }
    self.frequency = frequency
    interval = rule.interval
    let days = try rule.daysOfTheWeek.map { value in
      guard let day = Weekday(number: value.dayOfTheWeek) else {
        throw ServerError.unsupported("unknown recurrence weekday")
      }
      return Day(
        day: day,
        ordinal: value.weekNumber == 0 ? nil : value.weekNumber)
    }
    daysOfWeek = days.isEmpty ? nil : days
    func constraint(_ values: [Int]) -> [Int]? { values.isEmpty ? nil : values }
    daysOfMonth = constraint(rule.daysOfTheMonth)
    monthsOfYear = constraint(rule.monthsOfTheYear)
    weeksOfYear = constraint(rule.weeksOfTheYear)
    daysOfYear = constraint(rule.daysOfTheYear)
    setPositions = constraint(rule.setPositions)
    if let value = rule.end {
      guard
        (value.endDate != nil && value.occurrenceCount == 0)
          || (value.endDate == nil && value.occurrenceCount > 0)
      else { throw ServerError.unsupported("ambiguous recurrence end") }
      end = End(
        until: value.endDate, count: value.occurrenceCount > 0 ? value.occurrenceCount : nil)
    } else {
      end = nil
    }
  }
}
enum AlarmKind: String, Encodable, Sendable {
  case absolute = "AbsoluteAlarm"
  case relative = "RelativeAlarm"
  case location = "LocationAlarm"
}
struct AlarmView: Encodable {
  struct Geofence: Encodable {
    let title: String?
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let proximity: GeofenceProximity
    enum CodingKeys: String, CodingKey { case title, latitude, longitude, radiusMeters, proximity }
  }
  let kind: AlarmKind
  let at: String?
  let offsetSeconds: Double?
  let geofence: Geofence?
  enum CodingKeys: String, CodingKey { case kind, at, offsetSeconds, geofence }
  init(_ alarm: AlarmRecord) throws {
    guard alarm.relativeOffset.isFinite else {
      throw ServerError.unsupported("nonfinite alarm offset")
    }
    if alarm.structuredLocation != nil || alarm.proximity != .none {
      guard let location = alarm.structuredLocation, [.enter, .leave].contains(alarm.proximity),
        alarm.absoluteDate == nil, alarm.relativeOffset == 0,
        let latitude = location.latitude, let longitude = location.longitude,
        latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
        (-180...180).contains(longitude), location.radius.isFinite, location.radius >= 0
      else {
        throw ServerError.unsupported(
          "incomplete or combined location alarm; inspect rawAlarms")
      }
      kind = .location
      at = nil
      offsetSeconds = nil
      geofence = Geofence(
        title: location.title, latitude: latitude, longitude: longitude,
        radiusMeters: location.radius, proximity: alarm.proximity == .enter ? .arrive : .depart)
    } else if let date = alarm.absoluteDate {
      guard alarm.relativeOffset == 0 else {
        throw ServerError.unsupported("combined alarm triggers; inspect rawAlarms")
      }
      kind = .absolute
      at = date
      offsetSeconds = nil
      geofence = nil
    } else {
      kind = .relative
      at = nil
      offsetSeconds = alarm.relativeOffset
      geofence = nil
    }
  }
}
func recurrenceView(_ rules: [RecurrenceRecord]) throws -> RecurrenceView? {
  guard rules.count <= 1 else {
    throw ServerError.unsupported("multiple recurrence rules; inspect recurrenceRules")
  }
  return try rules.first.map(RecurrenceView.init)
}
