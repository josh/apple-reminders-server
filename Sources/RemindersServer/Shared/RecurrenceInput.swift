import Foundation

struct RecurrenceInput: Decodable, Sendable {
  let frequency: ScheduleFrequency
  let interval: Int
  let daysOfWeek: [Day]?
  let daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear, setPositions: [Int]?
  let end: End?

  struct Day: Decodable, Sendable {
    let day: Weekday
    let ordinal: Int?

    enum CodingKeys: String, CodingKey, CaseIterable { case day, ordinal }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      day = try c.decode(Weekday.self, forKey: .day)
      ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal)
    }
  }
  struct End: Decodable, Sendable {
    let until: String?
    let count: Int?

    enum CodingKeys: String, CodingKey, CaseIterable { case until, count }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      until = try c.decodeIfPresent(String.self, forKey: .until)
      count = try c.decodeIfPresent(Int.self, forKey: .count)
    }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case frequency, interval, daysOfWeek, daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear
    case setPositions, end
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    frequency = try c.decode(ScheduleFrequency.self, forKey: .frequency)
    interval = try c.decode(Int.self, forKey: .interval)
    daysOfWeek = try c.decodeIfPresent([Day].self, forKey: .daysOfWeek)
    daysOfMonth = try c.decodeIfPresent([Int].self, forKey: .daysOfMonth)
    monthsOfYear = try c.decodeIfPresent([Int].self, forKey: .monthsOfYear)
    weeksOfYear = try c.decodeIfPresent([Int].self, forKey: .weeksOfYear)
    daysOfYear = try c.decodeIfPresent([Int].self, forKey: .daysOfYear)
    setPositions = try c.decodeIfPresent([Int].self, forKey: .setPositions)
    end = try c.decodeIfPresent(End.self, forKey: .end)
  }
}

func recurrenceChange(_ input: RecurrenceInput) throws -> ReminderRecurrenceChange {
  let days = try input.daysOfWeek?.map { value -> ReminderRecurrenceChange.Day in
    if value.ordinal == 0 {
      throw ServerError.invalidArgument("omit ordinal instead of supplying zero")
    }
    return .init(weekday: value.day, ordinal: value.ordinal ?? 0)
  }
  var until: Date?
  var count: Int?
  if let end = input.end {
    guard (end.until != nil) != (end.count != nil) else {
      throw ServerError.invalidArgument(
        "recurrence end requires exactly one of until or count")
    }
    until = try end.until.map(parseTimestamp)
    count = end.count
  }
  return try ReminderRecurrenceChange(
    frequency: input.frequency, interval: input.interval, days: days,
    monthDays: input.daysOfMonth, months: input.monthsOfYear,
    weeks: input.weeksOfYear, yearDays: input.daysOfYear,
    positions: input.setPositions, until: until, count: count)
}
