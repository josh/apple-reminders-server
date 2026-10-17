import CoreGraphics
import EventKit
import Foundation

// Convert framework objects while confined to the store's main-thread operation.
// Only Sendable value records leave this boundary.
extension ComponentDate {
  init(_ value: DateComponents) {
    self.init(
      calendar: value.calendar.map { String(describing: $0.identifier) },
      timeZone: value.timeZone?.identifier, era: value.era, year: value.year,
      month: value.month, day: value.day, hour: value.hour, minute: value.minute,
      second: value.second, nanosecond: value.nanosecond, weekday: value.weekday,
      weekdayOrdinal: value.weekdayOrdinal, quarter: value.quarter,
      weekOfMonth: value.weekOfMonth, weekOfYear: value.weekOfYear,
      yearForWeekOfYear: value.yearForWeekOfYear, isLeapMonth: value.isLeapMonth ?? false)
  }
}
extension ListRecord {
  init(_ list: EKCalendar) {
    let color = list.cgColor?.converted(
      to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
    let hex = color?.components.flatMap { values -> String? in
      guard values.count == 4 else { return nil }
      return "#"
        + values.map {
          String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded()))
        }.joined()
    }
    self.init(
      id: list.calendarIdentifier, name: list.title, color: hex,
      source: SourceRecord(
        id: list.source.sourceIdentifier, title: list.source.title,
        type: list.source.sourceType.rawValue),
      allowsContentModifications: list.allowsContentModifications,
      isImmutable: list.isImmutable, isSubscribed: list.isSubscribed)
  }
}
extension ReminderRecord {
  init(_ item: EKReminder, now: Date, flagged: Bool?) throws {
    guard !item.calendarItemIdentifier.isEmpty,
      let listID = item.calendar?.calendarIdentifier, !listID.isEmpty,
      (0...9).contains(item.priority)
    else { throw ServerError.message("Invalid EventKit reminder identifiers or priority") }
    let formatter = timestampFormatter()
    func stamp(_ date: Date?) -> String? { date.map { formatter.string(from: $0) } }
    self.init(
      id: item.calendarItemIdentifier, externalId: item.calendarItemExternalIdentifier,
      listId: listID, name: item.title, body: item.notes, flagged: flagged,
      completed: item.isCompleted, priority: item.priority,
      completionDate: stamp(item.completionDate), creationDate: stamp(item.creationDate),
      modificationDate: stamp(item.lastModifiedDate), location: item.location,
      url: item.url?.absoluteString,
      startDateComponents: item.startDateComponents.map(ComponentDate.init),
      dueDateComponents: item.dueDateComponents.map(ComponentDate.init),
      dueDay: RemindersServer.dueDay(item.dueDateComponents),
      dueStatus: RemindersServer.dueStatus(item.dueDateComponents, now: now)
        .flatMap(DueStatus.init(rawValue:)) ?? .unknown,
      alarms: (item.alarms ?? []).map { AlarmRecord($0, stamp: stamp) },
      recurrenceRules: (item.recurrenceRules ?? []).map { RecurrenceRecord($0, stamp: stamp) })
  }
}
extension AlarmRecord {
  init(_ alarm: EKAlarm, stamp: (Date?) -> String?) {
    let proximity: AlarmProximity
    switch alarm.proximity {
    case .none: proximity = .none
    case .enter: proximity = .enter
    case .leave: proximity = .leave
    @unknown default: proximity = .unknown
    }
    self.init(
      absoluteDate: stamp(alarm.absoluteDate), relativeOffset: alarm.relativeOffset,
      proximity: proximity,
      structuredLocation: alarm.structuredLocation.map {
        StructuredLocation(
          title: $0.title, latitude: $0.geoLocation?.coordinate.latitude,
          longitude: $0.geoLocation?.coordinate.longitude, radius: $0.radius)
      })
  }
}
extension RecurrenceRecord {
  init(_ rule: EKRecurrenceRule, stamp: (Date?) -> String?) {
    let frequency: RecurrenceFrequency
    switch rule.frequency {
    case .daily: frequency = .daily
    case .weekly: frequency = .weekly
    case .monthly: frequency = .monthly
    case .yearly: frequency = .yearly
    @unknown default: frequency = .unknown
    }
    func integers(_ values: [NSNumber]?) -> [Int] { (values ?? []).map(\.intValue) }
    self.init(
      frequency: frequency, calendarIdentifier: rule.calendarIdentifier,
      interval: rule.interval, firstDayOfTheWeek: rule.firstDayOfTheWeek,
      daysOfTheWeek: (rule.daysOfTheWeek ?? []).map {
        RecurrenceDay(dayOfTheWeek: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber)
      }, daysOfTheMonth: integers(rule.daysOfTheMonth), daysOfTheYear: integers(rule.daysOfTheYear),
      weeksOfTheYear: integers(rule.weeksOfTheYear),
      monthsOfTheYear: integers(rule.monthsOfTheYear),
      setPositions: integers(rule.setPositions),
      end: rule.recurrenceEnd.map {
        RecurrenceEnd(endDate: stamp($0.endDate), occurrenceCount: $0.occurrenceCount)
      })
  }
}
