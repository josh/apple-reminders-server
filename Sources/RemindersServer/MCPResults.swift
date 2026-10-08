import Foundation

// MCP has fixed result objects, so date projection failures fail the tool call.
// Raw components remain available alongside the calendar-aware date fields.
struct MCPReminder: Encodable {
  let record: ReminderRecord
  let container: ContainerReference
  let remindMeDate: String?
  enum CodingKeys: CodingKey {
    case dueDate, allDayDueDate, startDate, allDayStartDate, timeZone, container, remindMeDate,
      alarms, rawAlarms, recurrence
  }
  func encode(to encoder: Encoder) throws {
    try record.encode(to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(container, forKey: .container)
    try c.encode(remindMeDate, forKey: .remindMeDate)
    try c.encode(record.alarms, forKey: .rawAlarms)
    try c.encode(record.alarms.map(AlarmView.init), forKey: .alarms)
    try c.encode(recurrenceView(record.recurrenceRules), forKey: .recurrence)
    let due = try projectDate(record.dueDateComponents)
    let start = try projectDate(record.startDateComponents)
    if let due, let start, due.timeZone != start.timeZone {
      throw ServerError.message("UNSUPPORTED: start and due have different time zones")
    }
    try c.encode(due?.timed == true ? due.map { timestamp($0.instant) } : nil, forKey: .dueDate)
    try c.encode(due?.timed == false ? due?.day : nil, forKey: .allDayDueDate)
    try c.encode(
      start?.timed == true ? start.map { timestamp($0.instant) } : nil, forKey: .startDate)
    try c.encode(start?.timed == false ? start?.day : nil, forKey: .allDayStartDate)
    try c.encode(due?.timeZone ?? start?.timeZone, forKey: .timeZone)
  }
}

func mcpReminders(_ records: [ReminderRecord]) async throws -> [MCPReminder] {
  guard !records.isEmpty else { return [] }
  let containers: [String: ContainerReference] = try await readRemindersData(
    "script-reminder-containers")
  let dates: [String: String?] = try await readRemindersData("script-alerts")
  return try records.map {
    try MCPReminder(
      record: $0, container: scriptLookup(containers, id: $0.id),
      remindMeDate: scriptLookup(dates, id: $0.id))
  }
}
struct MCPList: Encodable {
  let record: ListRecord
  let container: ContainerReference
  let emblem: String?
  enum CodingKeys: CodingKey { case container, emblem, allowsListModifications, subscribed }
  func encode(to encoder: Encoder) throws {
    try record.encode(to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(container, forKey: .container)
    try c.encode(emblem, forKey: .emblem)
    try c.encode(!record.isImmutable, forKey: .allowsListModifications)
    try c.encode(record.isSubscribed, forKey: .subscribed)
  }
}
func mcpLists(_ records: [ListRecord]) async throws -> [MCPList] {
  guard !records.isEmpty else { return [] }
  let ids = try records.map { record -> String in
    guard let uuid = UUID(uuidString: record.id) else {
      throw ServerError.message("Unsupported list identifier for automation")
    }
    return uuid.uuidString
  }
  for attempt in 0..<16 {
    let containers: [String: ContainerReference] = try await readRemindersData(
      "script-list-containers")
    let emblems: [String: String?] = try await readRemindersData("script-emblems")
    // A present null emblem is valid; only missing inventory entries are transient.
    if ids.allSatisfy({ containers.index(forKey: $0) != nil && emblems.index(forKey: $0) != nil }) {
      return try records.map {
        try MCPList(
          record: $0, container: scriptLookup(containers, id: $0.id),
          emblem: scriptLookup(emblems, id: $0.id))
      }
    }
    if attempt < 15 { try await Task.sleep(for: .seconds(2)) }
  }
  throw ServerError.message(
    "Automation inventory does not contain the requested list after bounded synchronization; retry")
}
