import CoreGraphics
import EventKit
import Foundation

// Convert framework objects on the main actor. Only Sendable value records leave it.
extension ComponentDate {
  init(_ value: DateComponents) {
    self.init(
      calendar: value.calendar?.identifier.storedName,
      timeZone: value.timeZone?.identifier, era: value.era, year: value.year,
      month: value.month, day: value.day, hour: value.hour, minute: value.minute,
      second: value.second, nanosecond: value.nanosecond, weekday: value.weekday,
      weekdayOrdinal: value.weekdayOrdinal, quarter: value.quarter,
      weekOfMonth: value.weekOfMonth, weekOfYear: value.weekOfYear,
      yearForWeekOfYear: value.yearForWeekOfYear, isLeapMonth: value.isLeapMonth ?? false)
  }
}
extension EKCalendar {
  // The server's rule for updating or deleting a list, also reported to clients.
  var allowsListModifications: Bool {
    !isImmutable && allowsContentModifications && !isSubscribed
  }
}
extension ListRecord {
  init(_ list: EKCalendar) throws {
    // EventKit leaves source nil on a list whose account is gone; the IUO would trap.
    guard let source = list.source else {
      throw ServerError.internalError("Reminder list \(list.calendarIdentifier) has no account")
    }
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
        id: source.sourceIdentifier, title: source.title, type: source.sourceType.rawValue),
      allowsContentModifications: list.allowsContentModifications,
      allowsListModifications: list.allowsListModifications, subscribed: list.isSubscribed)
  }
}
extension ReminderRecord {
  init(_ item: EKReminder, now: Date, flagged: Bool?) throws {
    guard !item.calendarItemIdentifier.isEmpty,
      let listID = item.calendar?.calendarIdentifier, !listID.isEmpty,
      (0...9).contains(item.priority)
    else { throw ServerError.internalError("Invalid EventKit reminder identifiers or priority") }
    func stamp(_ date: Date?) -> String? { date.map(timestamp) }
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
      dueStatus: RemindersServer.dueStatus(item.dueDateComponents, now: now),
      alarms: (item.alarms ?? []).map(AlarmRecord.init),
      recurrenceRules: (item.recurrenceRules ?? []).map(RecurrenceRecord.init))
  }
}
extension AlarmRecord {
  init(_ alarm: EKAlarm) {
    let proximity: AlarmProximity
    switch alarm.proximity {
    case .none: proximity = .none
    case .enter: proximity = .enter
    case .leave: proximity = .leave
    @unknown default: proximity = .unknown
    }
    self.init(
      absoluteDate: alarm.absoluteDate.map(timestamp), relativeOffset: alarm.relativeOffset,
      proximity: proximity,
      structuredLocation: alarm.structuredLocation.map {
        StructuredLocation(
          title: $0.title, latitude: $0.geoLocation?.coordinate.latitude,
          longitude: $0.geoLocation?.coordinate.longitude, radius: $0.radius)
      })
  }
}
extension RecurrenceRecord {
  init(_ rule: EKRecurrenceRule) {
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
        RecurrenceEnd(endDate: $0.endDate.map(timestamp), occurrenceCount: $0.occurrenceCount)
      })
  }
}
