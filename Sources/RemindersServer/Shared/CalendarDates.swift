import Foundation

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
  else { throw ServerError.unsupported("incomplete or non-Gregorian calendar date") }
  let dayString = String(format: "%04d-%02d-%02d", year, month, day)
  try validateDays(dayString, nil)
  let timed = value.hour != nil
  guard timed || [value.minute, value.second, value.nanosecond].allSatisfy({ $0 == nil }) else {
    throw ServerError.unsupported("time components without an hour")
  }
  guard (0...23).contains(value.hour ?? 0), (0...59).contains(value.minute ?? 0),
    (0...59).contains(value.second ?? 0), (0...999_999_999).contains(value.nanosecond ?? 0)
  else {
    throw ServerError.unsupported("invalid time components")
  }
  var calendar = Calendar(identifier: .gregorian)
  if let zone = value.timeZone {
    guard let zone = TimeZone(identifier: zone) else {
      throw ServerError.unsupported("invalid time zone")
    }
    calendar.timeZone = zone
  } else {
    calendar.timeZone = .current
  }
  let parts = DateComponents(
    year: year, month: month, day: day, hour: value.hour ?? 0,
    minute: value.minute ?? 0, second: value.second ?? 0, nanosecond: value.nanosecond ?? 0)
  guard let instant = calendar.date(from: parts) else {
    throw ServerError.unsupported("unresolvable calendar date")
  }
  let check = calendar.dateComponents(
    [.year, .month, .day, .hour, .minute, .second], from: instant)
  guard check.year == year, check.month == month, check.day == day,
    check.hour == parts.hour, check.minute == parts.minute, check.second == parts.second
  else {
    throw ServerError.unsupported("calendar date falls in a clock transition gap")
  }
  return CalendarDateProjection(
    instant: instant, day: dayString, timed: timed, timeZone: value.timeZone)
}
private let fractionalTimestamps: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()
private let wholeSecondTimestamps: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter
}()
func timestamp(_ date: Date) -> String {
  fractionalTimestamps.string(from: date)
}
func parseTimestamp(_ value: String) throws -> Date {
  let pattern =
    #"^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#
  guard value.range(of: pattern, options: .regularExpression) != nil else {
    throw ServerError.invalidArgument(
      "expected RFC 3339 timestamp with an explicit offset")
  }
  try validateDays(String(value.prefix(10)), nil)
  // ISO8601DateFormatter needs exactly three fraction digits; RFC 3339 allows any number.
  var value = value
  if let fraction = value.range(of: #"\.\d+"#, options: .regularExpression) {
    let digits = String(value[fraction].dropFirst().prefix(3))
    value.replaceSubrange(
      fraction, with: "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0))
  }
  if let date = fractionalTimestamps.date(from: value) { return date }
  guard let date = wholeSecondTimestamps.date(from: value) else {
    throw ServerError.invalidArgument("invalid timestamp")
  }
  return date
}

func orderReminders(
  _ items: [ReminderRecord], by field: ReminderSortField, direction: SortDirection
) throws
  -> [ReminderRecord]
{
  // Resolve fallible dates before sorting; never hide a failed projection in a comparator.
  var dates: [String: Date] = [:]
  for item in items {
    let value: String?
    switch field {
    case .dueDate:
      dates[item.id] = try projectDate(item.dueDateComponents)?.instant
      continue
    case .creationDate: value = item.creationDate
    case .modificationDate: value = item.modificationDate
    case .completionDate: value = item.completionDate
    case .name, .priority: continue
    }
    if let value { dates[item.id] = try parseTimestamp(value) }
  }
  func compare<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
    if a == b { return nil }
    guard let a else { return false }
    guard let b else { return true }
    return direction == .descending ? a > b : a < b
  }
  return items.sorted { a, b in
    let result: Bool?
    switch field {
    case .name: result = compare(a.name?.lowercased(), b.name?.lowercased())
    case .priority: result = compare(a.priority, b.priority)
    case .dueDate, .creationDate, .modificationDate, .completionDate:
      result = compare(dates[a.id], dates[b.id])
    }
    return result ?? (a.id < b.id)
  }
}

func validateDays(_ lower: String?, _ upper: String?) throws {
  for value in [lower, upper].compactMap({ $0 }) {
    let parts = value.split(separator: "-").map { Int($0) }
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}\z"#, options: .regularExpression) != nil,
      parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
      (1...9999).contains(year),
      DateComponents(year: year, month: month, day: day)
        .isValidDate(in: Calendar(identifier: .gregorian))
    else {
      throw ServerError.invalidArgument("date bounds must be valid Gregorian YYYY-MM-DD")
    }
  }
  if let lower, let upper, lower >= upper {
    throw ServerError.invalidArgument("dueOnOrAfter must precede dueBefore")
  }
}
func matchesDays(_ day: String?, _ lower: String?, _ upper: String?) -> Bool {
  guard lower != nil || upper != nil else { return true }
  guard let day else { return false }
  return (lower == nil || day >= lower!) && (upper == nil || day < upper!)
}
