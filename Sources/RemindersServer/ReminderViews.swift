import Foundation

struct ContainerReference: Codable, Sendable {
  let kind: String
  let id: String
}
struct RecurrenceView: Encodable {
  struct Day: Encodable {
    let day: String
    let ordinal: Int?
  }
  struct End: Encodable {
    let until: String?
    let count: Int?
  }
  let frequency: String, interval: Int
  let daysOfWeek: [Day]?
  let daysOfMonth: [Int]?, monthsOfYear: [Int]?, weeksOfYear: [Int]?, daysOfYear: [Int]?,
    setPositions: [Int]?
  let end: End?
  init(_ rule: RecurrenceRecord) throws {
    guard rule.frequency != .unknown else {
      throw ServerError.unsupported("unknown recurrence frequency")
    }
    frequency = rule.frequency.rawValue.uppercased()
    interval = rule.interval
    let weekdays = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
    let days = try rule.daysOfTheWeek.map { value in
      guard (1...7).contains(value.dayOfTheWeek) else {
        throw ServerError.unsupported("unknown recurrence weekday")
      }
      return Day(
        day: weekdays[value.dayOfTheWeek - 1],
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
struct AlarmView: Encodable {
  struct Geofence: Encodable {
    let title: String?
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let proximity: String
  }
  let kind: String
  let at: String?
  let offsetSeconds: Double?
  let geofence: Geofence?
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
      kind = "LocationAlarm"
      at = nil
      offsetSeconds = nil
      geofence = Geofence(
        title: location.title, latitude: latitude, longitude: longitude,
        radiusMeters: location.radius, proximity: alarm.proximity == .enter ? "ARRIVE" : "DEPART")
    } else if let date = alarm.absoluteDate {
      guard alarm.relativeOffset == 0 else {
        throw ServerError.unsupported("combined alarm triggers; inspect rawAlarms")
      }
      kind = "AbsoluteAlarm"
      at = date
      offsetSeconds = nil
      geofence = nil
    } else {
      kind = "RelativeAlarm"
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
