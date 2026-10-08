import Foundation

enum ServerError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case .message(let text): return text
    }
  }
}

struct ComponentDate: Codable, Sendable {
  let calendar: String?, timeZone: String?
  let era: Int?, year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?, second: Int?,
    nanosecond: Int?
  let weekday: Int?, weekdayOrdinal: Int?, quarter: Int?, weekOfMonth: Int?, weekOfYear: Int?,
    yearForWeekOfYear: Int?
  let isLeapMonth: Bool?

}
struct SourceRecord: Codable, Sendable {
  let id: String
  let title: String
  let type: Int
}
struct ListRecord: Codable, Sendable {
  let id: String, name: String
  let color: String?
  let source: SourceRecord
  let allowsContentModifications: Bool, isImmutable: Bool, isSubscribed: Bool
  enum StoreKeys: String, CodingKey {
    case id, title, source, allowsContentModifications, immutable, subscribed, color
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: StoreKeys.self)
    color = try values.decodeIfPresent(String.self, forKey: .color)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .title)
    source = try values.decode(SourceRecord.self, forKey: .source)
    allowsContentModifications = try values.decode(Bool.self, forKey: .allowsContentModifications)
    isImmutable = try values.decode(Bool.self, forKey: .immutable)
    isSubscribed = try values.decode(Bool.self, forKey: .subscribed)
  }
}
enum DueStatus: String, Codable, Sendable, CaseIterable {
  case overdue, today, future, unscheduled, unknown
}
enum ReminderSort: String, Codable, Sendable, CaseIterable {
  case idAsc = "id_asc"
  case priorityAsc = "priority_asc"
  case priorityDesc = "priority_desc"
  case createdAsc = "created_asc"
  case createdDesc = "created_desc"
}
struct StructuredLocation: Codable, Sendable {
  let title: String?
  let latitude: Double?
  let longitude: Double?
  let radius: Double
}
enum AlarmProximity: String, Codable, Sendable { case none, enter, leave, unknown }
enum RecurrenceFrequency: String, Codable, Sendable { case daily, weekly, monthly, yearly, unknown }
struct AlarmRecord: Codable, Sendable {
  let absoluteDate: String?
  let relativeOffset: Double
  let proximity: AlarmProximity
  let structuredLocation: StructuredLocation?
}
struct RecurrenceDay: Codable, Sendable {
  let dayOfTheWeek: Int
  let weekNumber: Int
}
struct RecurrenceEnd: Codable, Sendable {
  let endDate: String?
  let occurrenceCount: Int
}
struct RecurrenceRecord: Codable, Sendable {
  let frequency: RecurrenceFrequency
  let calendarIdentifier: String
  let interval: Int
  let firstDayOfTheWeek: Int
  let daysOfTheWeek: [RecurrenceDay]
  let daysOfTheMonth: [Int]
  let daysOfTheYear: [Int]
  let weeksOfTheYear: [Int]
  let monthsOfTheYear: [Int]
  let setPositions: [Int]
  let end: RecurrenceEnd?
}
func sortedReminders(_ items: [ReminderRecord], by order: ReminderSort) -> [ReminderRecord] {
  items.sorted { a, b in
    switch order {
    case .idAsc: break
    case .priorityAsc: if a.priority != b.priority { return a.priority < b.priority }
    case .priorityDesc: if a.priority != b.priority { return a.priority > b.priority }
    case .createdAsc, .createdDesc:
      if a.creationDate != b.creationDate {
        guard let x = a.creationDate else { return false }
        guard let y = b.creationDate else { return true }
        return order == .createdAsc ? x < y : x > y
      }
    }
    return a.id < b.id
  }
}
struct ReminderRecord: Codable, Sendable {
  let id: String, externalId: String?, listId: String?, name: String?, body: String?
  var flagged: Bool? = nil
  let completed: Bool, priority: Int
  let completionDate: String?, creationDate: String?, modificationDate: String?, location: String?,
    url: String?
  let startDateComponents: ComponentDate?, dueDateComponents: ComponentDate?
  let dueDay: String?
  let dueStatus: DueStatus
  let alarms: [AlarmRecord]
  let recurrenceRules: [RecurrenceRecord]
  enum CodingKeys: String, CodingKey {
    case id, externalId, listId, name, body, completed, flagged, priority, completionDate,
      creationDate, modificationDate, location, url, startDateComponents, dueDateComponents, dueDay,
      dueStatus, alarms, recurrenceRules
  }
  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(completed, forKey: .completed)
    try values.encode(priority, forKey: .priority)
    try values.encode(flagged, forKey: .flagged)
    try values.encode(dueDay, forKey: .dueDay)
    try values.encode(dueStatus, forKey: .dueStatus)
    try values.encode(alarms, forKey: .alarms)
    try values.encode(recurrenceRules, forKey: .recurrenceRules)
    try values.encodeIfPresent(externalId, forKey: .externalId)
    try values.encodeIfPresent(listId, forKey: .listId)
    try values.encodeIfPresent(name, forKey: .name)
    try values.encodeIfPresent(body, forKey: .body)
    try values.encodeIfPresent(completionDate, forKey: .completionDate)
    try values.encodeIfPresent(creationDate, forKey: .creationDate)
    try values.encodeIfPresent(modificationDate, forKey: .modificationDate)
    try values.encodeIfPresent(location, forKey: .location)
    try values.encodeIfPresent(url, forKey: .url)
    try values.encodeIfPresent(startDateComponents, forKey: .startDateComponents)
    try values.encodeIfPresent(dueDateComponents, forKey: .dueDateComponents)
  }
  enum StoreKeys: String, CodingKey {
    case id, externalId, listId, title, notes, completed, flagged, priority, completionDate,
      creationDate, lastModifiedDate, location, url, startDateComponents, dueDateComponents, dueDay,
      dueStatus, alarms, recurrenceRules
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: StoreKeys.self)
    id = try values.decode(String.self, forKey: .id)
    listId = try values.decode(String.self, forKey: .listId)
    externalId = try values.decodeIfPresent(String.self, forKey: .externalId)
    name = try values.decodeIfPresent(String.self, forKey: .title)
    body = try values.decodeIfPresent(String.self, forKey: .notes)
    completed = try values.decode(Bool.self, forKey: .completed)
    priority = try values.decode(Int.self, forKey: .priority)
    flagged = try values.decodeIfPresent(Bool.self, forKey: .flagged)
    completionDate = try values.decodeIfPresent(String.self, forKey: .completionDate)
    creationDate = try values.decodeIfPresent(String.self, forKey: .creationDate)
    modificationDate = try values.decodeIfPresent(String.self, forKey: .lastModifiedDate)
    location = try values.decodeIfPresent(String.self, forKey: .location)
    url = try values.decodeIfPresent(String.self, forKey: .url)
    startDateComponents = try values.decodeIfPresent(
      ComponentDate.self, forKey: .startDateComponents)
    dueDateComponents = try values.decodeIfPresent(ComponentDate.self, forKey: .dueDateComponents)
    dueDay = try values.decodeIfPresent(String.self, forKey: .dueDay)
    dueStatus = try values.decodeIfPresent(DueStatus.self, forKey: .dueStatus) ?? .unknown
    alarms = try values.decode([AlarmRecord].self, forKey: .alarms)
    recurrenceRules = try values.decode([RecurrenceRecord].self, forKey: .recurrenceRules)
    guard !id.isEmpty, listId?.isEmpty == false, (0...9).contains(priority) else {
      throw ServerError.message("Invalid EventKit reminder identifiers or priority")
    }
  }
}
struct ListsSnapshot: Codable, Sendable {
  let lists: [ListRecord]
  let defaultListId: String?
}
struct RemindersSnapshot: Codable, Sendable { let reminders: [ReminderRecord] }

struct Inventory: Codable, Sendable {
  let lists: [ListRecord]
  let reminders: [ReminderRecord]
  let defaultListId: String?
  var orderedLists: [ListRecord] { lists.sorted { $0.id < $1.id } }
  var accounts: [AccountRecord] {
    var seen = Set<String>()
    return orderedLists.compactMap {
      seen.insert($0.source.id).inserted
        ? AccountRecord(id: $0.source.id, name: $0.source.title) : nil
    }.sorted { $0.id < $1.id }
  }
  var defaultList: ListRecord? { lists.first { $0.id == defaultListId } }
  var defaultAccount: AccountRecord? { accounts.first { $0.id == defaultList?.source.id } }
}
struct AccountRecord: Codable, Sendable {
  let id: String
  let name: String
}
struct ListSummary: Codable, Sendable {
  let listId: String
  let total: Int, completed: Int, incomplete: Int, overdue: Int, scheduled: Int, recurring: Int,
    withAlarms: Int
}
func summarize(_ inventory: Inventory, listId: String) -> ListSummary {
  let items = inventory.reminders.filter { $0.listId == listId }
  let completed = items.filter(\.completed).count
  return ListSummary(
    listId: listId, total: items.count, completed: completed, incomplete: items.count - completed,
    overdue: items.filter { !$0.completed && $0.dueStatus == .overdue }.count,
    scheduled: items.filter { $0.dueDateComponents != nil }.count,
    recurring: items.filter { !$0.recurrenceRules.isEmpty }.count,
    withAlarms: items.filter { !$0.alarms.isEmpty }.count)
}
func validateDays(_ lower: String?, _ upper: String?) throws {
  for value in [lower, upper].compactMap({ $0 }) {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard value.utf8.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2,
      parts[2].count == 2,
      value.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
      let year = Int(parts[0]), (1...9999).contains(year), let month = Int(parts[1]),
      (1...12).contains(month), let day = Int(parts[2])
    else {
      throw ServerError.message("INVALID_ARGUMENT: date bounds must be valid Gregorian YYYY-MM-DD")
    }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...days[month - 1]).contains(day) else {
      throw ServerError.message("INVALID_ARGUMENT: invalid Gregorian date")
    }
  }
  if let lower, let upper, lower >= upper {
    throw ServerError.message("INVALID_ARGUMENT: dueOnOrAfter must precede dueBefore")
  }
}
func matchesDays(_ day: String?, _ lower: String?, _ upper: String?) -> Bool {
  guard lower != nil || upper != nil else { return true }
  guard let day else { return false }
  return (lower == nil || day >= lower!) && (upper == nil || day < upper!)
}
