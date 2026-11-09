import Foundation

// MCP results use EventKit only; clients cannot deselect fields, so no Reminders
// automation read can hold up or fail a call. Flags, alert dates, containers, and
// emblems are not included. Projection failures fail the call.
struct MCPReminder: Encodable {
  let record: ReminderRecord
  let alarms: [AlarmView]
  let recurrence: RecurrenceView?
  let dueDate, allDayDueDate, startDate, allDayStartDate, timeZone: String?

  init(record: ReminderRecord) throws {
    self.record = record
    let due = try projectDate(record.dueDateComponents)
    let start = try projectDate(record.startDateComponents)
    if let due, let start, due.timeZone != start.timeZone {
      throw ServerError.unsupported("start and due have different time zones")
    }
    alarms = try record.alarms.map(AlarmView.init)
    recurrence = try recurrenceView(record.recurrenceRules)
    dueDate = due?.timed == true ? due.map { timestamp($0.instant) } : nil
    allDayDueDate = due?.timed == false ? due?.day : nil
    startDate = start?.timed == true ? start.map { timestamp($0.instant) } : nil
    allDayStartDate = start?.timed == false ? start?.day : nil
    timeZone = due?.timeZone ?? start?.timeZone
  }

  enum CodingKeys: String, CodingKey {
    case id, externalId, listId, name, body, flagged, completed, priority, completionDate
    case creationDate, modificationDate, location, url, startDateComponents, dueDateComponents
    case dueDay, dueStatus, rawAlarms, alarms, recurrenceRules, recurrence, dueDate
    case allDayDueDate, startDate, allDayStartDate, timeZone
  }
  // Projected fields are always present, as null when absent; stored optional fields are
  // omitted when absent.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(record.id, forKey: .id)
    try c.encodeIfPresent(record.externalId, forKey: .externalId)
    try c.encodeIfPresent(record.listId, forKey: .listId)
    try c.encodeIfPresent(record.name, forKey: .name)
    try c.encodeIfPresent(record.body, forKey: .body)
    try c.encodeIfPresent(record.flagged, forKey: .flagged)
    try c.encode(record.completed, forKey: .completed)
    try c.encode(record.priority, forKey: .priority)
    try c.encodeIfPresent(record.completionDate, forKey: .completionDate)
    try c.encodeIfPresent(record.creationDate, forKey: .creationDate)
    try c.encodeIfPresent(record.modificationDate, forKey: .modificationDate)
    try c.encodeIfPresent(record.location, forKey: .location)
    try c.encodeIfPresent(record.url, forKey: .url)
    try c.encodeIfPresent(record.startDateComponents, forKey: .startDateComponents)
    try c.encodeIfPresent(record.dueDateComponents, forKey: .dueDateComponents)
    try c.encode(record.dueDay, forKey: .dueDay)
    try c.encode(record.dueStatus, forKey: .dueStatus)
    try c.encode(record.alarms, forKey: .rawAlarms)
    try c.encode(alarms, forKey: .alarms)
    try c.encode(record.recurrenceRules, forKey: .recurrenceRules)
    try c.encode(recurrence, forKey: .recurrence)
    try c.encode(dueDate, forKey: .dueDate)
    try c.encode(allDayDueDate, forKey: .allDayDueDate)
    try c.encode(startDate, forKey: .startDate)
    try c.encode(allDayStartDate, forKey: .allDayStartDate)
    try c.encode(timeZone, forKey: .timeZone)
  }
}
