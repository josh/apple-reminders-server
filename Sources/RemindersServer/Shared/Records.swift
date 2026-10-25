import Foundation

// Codes are the client contract. GraphQL reports them in extensions.code and
// MCP in the error payload; the message is a sentence for people.
enum ErrorCode: String, Sendable {
  case invalidArgument = "INVALID_ARGUMENT"
  case notFound = "NOT_FOUND"
  case forbidden = "FORBIDDEN"
  case readOnly = "READ_ONLY"
  case unsupported = "UNSUPPORTED"
  case unsupportedOperation = "UNSUPPORTED_OPERATION"
  case listNotEmpty = "LIST_NOT_EMPTY"
  case writeFailed = "WRITE_FAILED"
  case writeApplied = "WRITE_APPLIED"
  case showApplied = "SHOW_APPLIED"
  case showFailed = "SHOW_FAILED"
  case internalError = "INTERNAL"
}
struct ServerError: Error, CustomStringConvertible, Sendable {
  let code: ErrorCode
  let message: String
  var description: String { message }
  static func invalidArgument(_ message: String) -> Self {
    .init(code: .invalidArgument, message: message)
  }
  static func notFound(_ message: String) -> Self { .init(code: .notFound, message: message) }
  static func forbidden(_ message: String) -> Self { .init(code: .forbidden, message: message) }
  static func readOnly(_ message: String) -> Self { .init(code: .readOnly, message: message) }
  static func unsupported(_ message: String) -> Self { .init(code: .unsupported, message: message) }
  static func unsupportedOperation(_ message: String) -> Self {
    .init(code: .unsupportedOperation, message: message)
  }
  static func listNotEmpty(_ message: String) -> Self {
    .init(code: .listNotEmpty, message: message)
  }
  static func writeFailed(_ message: String) -> Self { .init(code: .writeFailed, message: message) }
  static func writeApplied(_ message: String) -> Self {
    .init(code: .writeApplied, message: message)
  }
  static func showApplied(_ message: String) -> Self { .init(code: .showApplied, message: message) }
  static func showFailed(_ message: String) -> Self { .init(code: .showFailed, message: message) }
  static func internalError(_ message: String) -> Self {
    .init(code: .internalError, message: message)
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
  let allowsContentModifications, allowsListModifications, subscribed: Bool
}

enum DueStatus: String, Codable, Sendable, CaseIterable {
  case overdue, today, future, unscheduled, unknown
}
// Index + 1 is the Gregorian weekday number EventKit uses.
let weekdayNames = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
let reminderSortFields = [
  "NAME", "DUE_DATE", "PRIORITY", "CREATION_DATE", "MODIFICATION_DATE", "COMPLETION_DATE",
]
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
    try values.encodeIfPresent(flagged, forKey: .flagged)
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
}

struct RemindersData: Codable, Sendable {
  let lists: [ListRecord]
  let reminders: [ReminderRecord]
  let defaultListId: String?
  var accounts: [AccountRecord] {
    var seen = Set<String>()
    return lists.compactMap {
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
func summarize(_ data: RemindersData, listId: String) -> ListSummary {
  let items = data.reminders.filter { $0.listId == listId }
  let completed = items.filter(\.completed).count
  return ListSummary(
    listId: listId, total: items.count, completed: completed, incomplete: items.count - completed,
    overdue: items.filter { !$0.completed && $0.dueStatus == .overdue }.count,
    scheduled: items.filter { $0.dueDateComponents != nil }.count,
    recurring: items.filter { !$0.recurrenceRules.isEmpty }.count,
    withAlarms: items.filter { !$0.alarms.isEmpty }.count)
}
