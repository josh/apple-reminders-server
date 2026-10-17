import EventKit
import Foundation

/// Validated recurrence values; EventKit objects are constructed on the main thread.
struct ReminderRecurrenceChange: Sendable {
  enum Frequency: String, Sendable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"
    case yearly = "YEARLY"
  }
  struct Day: Sendable, Hashable {
    let weekday: Int
    let ordinal: Int
  }
  let frequency: Frequency
  let interval: Int
  let days: [Day]?
  let monthDays: [Int]?, months: [Int]?, weeks: [Int]?, yearDays: [Int]?, positions: [Int]?
  let until: Date?
  let count: Int?

  init(
    frequency: Frequency, interval: Int, days: [Day]?, monthDays: [Int]?, months: [Int]?,
    weeks: [Int]?, yearDays: [Int]?, positions: [Int]?, until: Date?, count: Int?
  ) throws {
    func require(_ condition: Bool, _ message: String) throws {
      guard condition else { throw ServerError.message("INVALID_ARGUMENT: recurrence " + message) }
    }
    try require(interval > 0 && interval <= Int(Int32.max), "interval must be 1...2147483647")
    try require(until == nil || count == nil, "end must choose until or count")
    if let count {
      try require(count > 0 && count <= Int(Int32.max), "count must be 1...2147483647")
    }
    func numbers(_ values: [Int]?, max: Int, positive: Bool = false) throws {
      guard let values else { return }
      try require(
        !values.isEmpty && Set(values).count == values.count
          && values.allSatisfy { $0 != 0 && $0 >= (positive ? 1 : -max) && $0 <= max },
        "selectors must be nonempty, unique and within range")
    }
    try numbers(monthDays, max: 31)
    try numbers(months, max: 12, positive: true)
    try numbers(weeks, max: 53)
    try numbers(yearDays, max: 366)
    try numbers(positions, max: 366)
    if let days {
      try require(
        !days.isEmpty && Set(days).count == days.count && frequency != .daily,
        "weekdays require a non-daily frequency and unique nonempty values")
      for day in days {
        let limit = frequency == .monthly ? 5 : 53
        try require(
          (1...7).contains(day.weekday) && (-limit...limit).contains(day.ordinal),
          "weekday or ordinal is outside its frequency's range")
        try require(
          day.ordinal == 0 || (frequency != .weekly && weeks == nil),
          "ordinal weekdays require monthly/yearly frequency without weeksOfYear")
      }
    }
    try require(monthDays == nil || frequency == .monthly, "daysOfMonth requires monthly frequency")
    try require(
      (months == nil && weeks == nil && yearDays == nil) || frequency == .yearly,
      "year selectors require yearly frequency")
    try require(
      positions == nil || days != nil || monthDays != nil || months != nil || weeks != nil
        || yearDays != nil, "setPositions requires another selector")
    self.frequency = frequency
    self.interval = interval
    self.days = days
    self.monthDays = monthDays
    self.months = months
    self.weeks = weeks
    self.yearDays = yearDays
    self.positions = positions
    self.until = until
    self.count = count
  }

  func eventKitRule() -> EKRecurrenceRule {
    let eventKitFrequency: EKRecurrenceFrequency
    switch frequency {
    case .daily: eventKitFrequency = .daily
    case .weekly: eventKitFrequency = .weekly
    case .monthly: eventKitFrequency = .monthly
    case .yearly: eventKitFrequency = .yearly
    }
    let end =
      until.map { EKRecurrenceEnd(end: $0) } ?? count.map { EKRecurrenceEnd(occurrenceCount: $0) }
    func numbers(_ values: [Int]?) -> [NSNumber]? { values?.map { NSNumber(value: $0) } }
    return EKRecurrenceRule(
      recurrenceWith: eventKitFrequency, interval: interval,
      daysOfTheWeek: days?.map {
        EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0.weekday)!, weekNumber: $0.ordinal)
      },
      daysOfTheMonth: numbers(monthDays), monthsOfTheYear: numbers(months),
      weeksOfTheYear: numbers(weeks),
      daysOfTheYear: numbers(yearDays), setPositions: numbers(positions), end: end)
  }
}
