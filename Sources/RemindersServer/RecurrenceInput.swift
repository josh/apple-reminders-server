import Foundation

func parseRecurrenceInput(_ input: MutationInput) throws -> ReminderRecurrenceChange {
  try input.checkKeys([
    "frequency", "interval", "daysOfWeek", "daysOfMonth", "monthsOfYear", "weeksOfYear",
    "daysOfYear", "setPositions", "end",
  ])
  guard
    let frequency = ReminderRecurrenceChange.Frequency(
      rawValue: try input["frequency"].stringValue())
  else { throw ServerError.message("INVALID_ARGUMENT: unknown recurrence frequency") }
  func present(_ value: MutationInput) -> Bool { value != .undefined && value != .null }
  func numbers(_ key: String) throws -> [Int]? {
    guard present(input[key]) else { return nil }
    return try input[key].arrayValue().map { try $0.intValue() }
  }
  var days: [ReminderRecurrenceChange.Day]?
  if present(input["daysOfWeek"]) {
    days = try input["daysOfWeek"].arrayValue().map { value in
      try value.checkKeys(["day", "ordinal"])
      let names = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
      guard let index = names.firstIndex(of: try value["day"].stringValue()) else {
        throw ServerError.message("INVALID_ARGUMENT: unknown weekday")
      }
      let ordinal = present(value["ordinal"]) ? try value["ordinal"].intValue() : 0
      if present(value["ordinal"]) && ordinal == 0 {
        throw ServerError.message("INVALID_ARGUMENT: omit ordinal instead of supplying zero")
      }
      return .init(weekday: index + 1, ordinal: ordinal)
    }
  }
  var until: Date?
  var count: Int?
  if present(input["end"]) {
    let end = input["end"]
    try end.checkKeys(["until", "count"])
    guard present(end["until"]) != present(end["count"]) else {
      throw ServerError.message(
        "INVALID_ARGUMENT: recurrence end requires exactly one of until or count")
    }
    if present(end["until"]) { until = try parseTimestamp(end["until"].stringValue()) }
    if present(end["count"]) { count = try end["count"].intValue() }
  }
  return try ReminderRecurrenceChange(
    frequency: frequency, interval: input["interval"].intValue(), days: days,
    monthDays: numbers("daysOfMonth"), months: numbers("monthsOfYear"),
    weeks: numbers("weeksOfYear"), yearDays: numbers("daysOfYear"),
    positions: numbers("setPositions"), until: until, count: count)
}
