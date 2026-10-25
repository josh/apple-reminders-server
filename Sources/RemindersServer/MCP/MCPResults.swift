import Foundation

// MCP results use EventKit only; clients cannot deselect fields, so no Reminders
// automation read can hold up or fail a call. Flags, alert dates, containers, and
// emblems are not included. Date projection failures fail the call.
struct MCPReminder: Encodable {
  let record: ReminderRecord
  enum CodingKeys: CodingKey {
    case dueDate, allDayDueDate, startDate, allDayStartDate, timeZone, alarms, rawAlarms,
      recurrence
  }
  func encode(to encoder: Encoder) throws {
    try record.encode(to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(record.alarms, forKey: .rawAlarms)
    try c.encode(record.alarms.map(AlarmView.init), forKey: .alarms)
    try c.encode(recurrenceView(record.recurrenceRules), forKey: .recurrence)
    let due = try projectDate(record.dueDateComponents)
    let start = try projectDate(record.startDateComponents)
    if let due, let start, due.timeZone != start.timeZone {
      throw ServerError.unsupported("start and due have different time zones")
    }
    try c.encode(due?.timed == true ? due.map { timestamp($0.instant) } : nil, forKey: .dueDate)
    try c.encode(due?.timed == false ? due?.day : nil, forKey: .allDayDueDate)
    try c.encode(
      start?.timed == true ? start.map { timestamp($0.instant) } : nil, forKey: .startDate)
    try c.encode(start?.timed == false ? start?.day : nil, forKey: .allDayStartDate)
    try c.encode(due?.timeZone ?? start?.timeZone, forKey: .timeZone)
  }
}
