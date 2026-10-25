import Foundation

struct RecurrenceInput: Decodable, Sendable {
  let frequency: String
  let interval: Int
  let daysOfWeek: InputField<[Day]>
  let daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear, setPositions: InputField<[Int]>
  let end: InputField<End>

  struct Day: Decodable, Sendable {
    let day: String
    let ordinal: InputField<Int>

    enum CodingKeys: String, CodingKey, CaseIterable { case day, ordinal }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      day = try c.decode(String.self, forKey: .day)
      ordinal = try c.field(.ordinal)
    }
  }
  struct End: Decodable, Sendable {
    let until: InputField<String>
    let count: InputField<Int>

    enum CodingKeys: String, CodingKey, CaseIterable { case until, count }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      until = try c.field(.until)
      count = try c.field(.count)
    }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case frequency, interval, daysOfWeek, daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear
    case setPositions, end
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    frequency = try c.decode(String.self, forKey: .frequency)
    interval = try c.decode(Int.self, forKey: .interval)
    daysOfWeek = try c.field(.daysOfWeek)
    daysOfMonth = try c.field(.daysOfMonth)
    monthsOfYear = try c.field(.monthsOfYear)
    weeksOfYear = try c.field(.weeksOfYear)
    daysOfYear = try c.field(.daysOfYear)
    setPositions = try c.field(.setPositions)
    end = try c.field(.end)
  }
}

func recurrenceChange(_ input: RecurrenceInput) throws -> ReminderRecurrenceChange {
  guard let frequency = RecurrenceFrequency(rawValue: input.frequency.lowercased()),
    input.frequency == input.frequency.uppercased()
  else { throw ServerError.invalidArgument("unknown recurrence frequency") }
  let days = try input.daysOfWeek.value?.map { value -> ReminderRecurrenceChange.Day in
    guard let index = weekdayNames.firstIndex(of: value.day) else {
      throw ServerError.invalidArgument("unknown weekday")
    }
    if value.ordinal.value == 0 {
      throw ServerError.invalidArgument("omit ordinal instead of supplying zero")
    }
    return .init(weekday: index + 1, ordinal: value.ordinal.value ?? 0)
  }
  var until: Date?
  var count: Int?
  if let end = input.end.value {
    guard (end.until.value != nil) != (end.count.value != nil) else {
      throw ServerError.invalidArgument(
        "recurrence end requires exactly one of until or count")
    }
    until = try end.until.value.map(parseTimestamp)
    count = end.count.value
  }
  return try ReminderRecurrenceChange(
    frequency: frequency, interval: input.interval, days: days,
    monthDays: input.daysOfMonth.value, months: input.monthsOfYear.value,
    weeks: input.weeksOfYear.value, yearDays: input.daysOfYear.value,
    positions: input.setPositions.value, until: until, count: count)
}
