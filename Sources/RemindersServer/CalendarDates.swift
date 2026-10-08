import Foundation

// Calendar projections shared by the API adapters.
struct CalendarDateProjection {
  let instant: Date
  let day: String
  let timed: Bool
  let timeZone: String?
}
func projectDate(_ value: ComponentDate?) throws -> CalendarDateProjection? {
  guard let value else { return nil }
  guard value.calendar == nil || value.calendar == "gregorian",
    value.era == nil || value.era == 1,
    let year = value.year, let month = value.month, let day = value.day,
    (1...9999).contains(year)
  else { throw ServerError.message("UNSUPPORTED: incomplete or non-Gregorian calendar date") }
  let dayString = String(format: "%04d-%02d-%02d", year, month, day)
  try validateDays(dayString, nil)
  let timed = value.hour != nil
  guard timed || [value.minute, value.second, value.nanosecond].allSatisfy({ $0 == nil }) else {
    throw ServerError.message("UNSUPPORTED: time components without an hour")
  }
  guard (0...23).contains(value.hour ?? 0), (0...59).contains(value.minute ?? 0),
    (0...59).contains(value.second ?? 0), (0...999_999_999).contains(value.nanosecond ?? 0)
  else {
    throw ServerError.message("UNSUPPORTED: invalid time components")
  }
  var calendar = Calendar(identifier: .gregorian)
  if let zone = value.timeZone {
    guard let zone = TimeZone(identifier: zone) else {
      throw ServerError.message("UNSUPPORTED: invalid time zone")
    }
    calendar.timeZone = zone
  } else {
    calendar.timeZone = .current
  }
  let parts = DateComponents(
    year: year, month: month, day: day, hour: value.hour ?? 0,
    minute: value.minute ?? 0, second: value.second ?? 0, nanosecond: value.nanosecond ?? 0)
  guard let instant = calendar.date(from: parts) else {
    throw ServerError.message("UNSUPPORTED: unresolvable calendar date")
  }
  let check = calendar.dateComponents(
    [.year, .month, .day, .hour, .minute, .second], from: instant)
  guard check.year == year, check.month == month, check.day == day,
    check.hour == parts.hour, check.minute == parts.minute, check.second == parts.second
  else {
    throw ServerError.message("UNSUPPORTED: calendar date falls in a clock transition gap")
  }
  return CalendarDateProjection(
    instant: instant, day: dayString, timed: timed, timeZone: value.timeZone)
}
func timestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}
func parseTimestamp(_ value: String) throws -> Date {
  let pattern =
    #"^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#
  guard value.range(of: pattern, options: .regularExpression) != nil else {
    throw ServerError.message(
      "INVALID_ARGUMENT: expected RFC 3339 timestamp with an explicit offset")
  }
  try validateDays(String(value.prefix(10)), nil)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: value) { return date }
  formatter.formatOptions = [.withInternetDateTime]
  guard let date = formatter.date(from: value) else {
    throw ServerError.message("INVALID_ARGUMENT: invalid timestamp")
  }
  return date
}

func orderReminders(_ items: [ReminderRecord], field: String, descending: Bool) throws
  -> [ReminderRecord]
{
  // Resolve fallible dates before sorting; never hide a failed projection in a comparator.
  var dates: [String: Date] = [:]
  for item in items {
    let value: String?
    switch field {
    case "DUE_DATE":
      dates[item.id] = try projectDate(item.dueDateComponents)?.instant
      continue
    case "CREATION_DATE": value = item.creationDate
    case "MODIFICATION_DATE": value = item.modificationDate
    case "COMPLETION_DATE": value = item.completionDate
    default: continue
    }
    if let value { dates[item.id] = try parseTimestamp(value) }
  }
  func compare<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
    if a == b { return nil }
    guard let a else { return false }
    guard let b else { return true }
    return descending ? a > b : a < b
  }
  return items.sorted { a, b in
    let result: Bool?
    switch field {
    case "NAME": result = compare(a.name?.lowercased(), b.name?.lowercased())
    case "PRIORITY": result = compare(a.priority, b.priority)
    default: result = compare(dates[a.id], dates[b.id])
    }
    return result ?? (a.id < b.id)
  }
}
