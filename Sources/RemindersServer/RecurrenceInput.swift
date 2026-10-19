import Foundation

func parseRecurrenceInput(_ input: MutationInput) throws -> ReminderRecurrenceChange {
  try input.checkKeys([
    "frequency", "interval", "daysOfWeek", "daysOfMonth", "monthsOfYear", "weeksOfYear",
    "daysOfYear", "setPositions", "end",
  ])
  guard
    let frequency = ReminderRecurrenceChange.Frequency(
      rawValue: try input["frequency"].stringValue())
  else { throw ServerError.invalidArgument("unknown recurrence frequency") }
  func numbers(_ key: String) throws -> [Int]? {
    guard input[key].isSet else { return nil }
    return try input[key].arrayValue().map { try $0.intValue() }
  }
  var days: [ReminderRecurrenceChange.Day]?
  if input["daysOfWeek"].isSet {
    days = try input["daysOfWeek"].arrayValue().map { value in
      try value.checkKeys(["day", "ordinal"])
      let names = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
      guard let index = names.firstIndex(of: try value["day"].stringValue()) else {
        throw ServerError.invalidArgument("unknown weekday")
      }
      let ordinal = value["ordinal"].isSet ? try value["ordinal"].intValue() : 0
      if value["ordinal"].isSet && ordinal == 0 {
        throw ServerError.invalidArgument("omit ordinal instead of supplying zero")
      }
      return .init(weekday: index + 1, ordinal: ordinal)
    }
  }
  var until: Date?
  var count: Int?
  if input["end"].isSet {
    let end = input["end"]
    try end.checkKeys(["until", "count"])
    guard end["until"].isSet != end["count"].isSet else {
      throw ServerError.invalidArgument(
        "recurrence end requires exactly one of until or count")
    }
    if end["until"].isSet { until = try parseTimestamp(end["until"].stringValue()) }
    if end["count"].isSet { count = try end["count"].intValue() }
  }
  return try ReminderRecurrenceChange(
    frequency: frequency, interval: input["interval"].intValue(), days: days,
    monthDays: numbers("daysOfMonth"), months: numbers("monthsOfYear"),
    weeks: numbers("weeksOfYear"), yearDays: numbers("daysOfYear"),
    positions: numbers("setPositions"), until: until, count: count)
}
