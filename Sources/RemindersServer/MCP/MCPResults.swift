import Foundation

// MCP results use EventKit only; clients cannot deselect fields, so no Reminders
// automation read can hold up or fail a call. Flags, alert dates, containers, and
// emblems are not included. Projection failures fail the call.
struct MCPReminder: Encodable {
  let id: String
  let externalId, listId, name, body: String?
  let flagged: Bool?
  let completed: Bool
  let priority: Int
  let completionDate, creationDate, modificationDate, location, url: String?
  let startDateComponents, dueDateComponents: ComponentDate?
  let dueDay: String?
  let dueStatus: DueStatus
  let rawAlarms: [AlarmRecord]
  let alarms: [AlarmView]
  let recurrenceRules: [RecurrenceRecord]
  let recurrence: RecurrenceView?
  let dueDate, allDayDueDate, startDate, allDayStartDate, timeZone: String?

  init(record: ReminderRecord) throws {
    let due = try projectDate(record.dueDateComponents)
    let start = try projectDate(record.startDateComponents)
    if let due, let start, due.timeZone != start.timeZone {
      throw ServerError.unsupported("start and due have different time zones")
    }
    id = record.id
    externalId = record.externalId
    listId = record.listId
    name = record.name
    body = record.body
    flagged = record.flagged
    completed = record.completed
    priority = record.priority
    completionDate = record.completionDate
    creationDate = record.creationDate
    modificationDate = record.modificationDate
    location = record.location
    url = record.url
    startDateComponents = record.startDateComponents
    dueDateComponents = record.dueDateComponents
    dueDay = record.dueDay
    dueStatus = record.dueStatus
    rawAlarms = record.alarms
    alarms = try record.alarms.map(AlarmView.init)
    recurrenceRules = record.recurrenceRules
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
    try c.encode(id, forKey: .id)
    try c.encodeIfPresent(externalId, forKey: .externalId)
    try c.encodeIfPresent(listId, forKey: .listId)
    try c.encodeIfPresent(name, forKey: .name)
    try c.encodeIfPresent(body, forKey: .body)
    try c.encodeIfPresent(flagged, forKey: .flagged)
    try c.encode(completed, forKey: .completed)
    try c.encode(priority, forKey: .priority)
    try c.encodeIfPresent(completionDate, forKey: .completionDate)
    try c.encodeIfPresent(creationDate, forKey: .creationDate)
    try c.encodeIfPresent(modificationDate, forKey: .modificationDate)
    try c.encodeIfPresent(location, forKey: .location)
    try c.encodeIfPresent(url, forKey: .url)
    try c.encodeIfPresent(startDateComponents, forKey: .startDateComponents)
    try c.encodeIfPresent(dueDateComponents, forKey: .dueDateComponents)
    try c.encode(dueDay, forKey: .dueDay)
    try c.encode(dueStatus, forKey: .dueStatus)
    try c.encode(rawAlarms, forKey: .rawAlarms)
    try c.encode(alarms, forKey: .alarms)
    try c.encode(recurrenceRules, forKey: .recurrenceRules)
    try c.encode(recurrence, forKey: .recurrence)
    try c.encode(dueDate, forKey: .dueDate)
    try c.encode(allDayDueDate, forKey: .allDayDueDate)
    try c.encode(startDate, forKey: .startDate)
    try c.encode(allDayStartDate, forKey: .allDayStartDate)
    try c.encode(timeZone, forKey: .timeZone)
  }
}
