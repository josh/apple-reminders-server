import Foundation

// One filter for GraphQL and MCP searches.
enum SortDirection: String, CaseIterable, Decodable, Sendable {
  case ascending = "ASC"
  case descending = "DESC"
}
struct Search: Sendable {
  // Reminders sort by this field when set; lists sort by name when sortListsByName is set.
  var reminderOrder: ReminderSortField?
  var sortListsByName = false
  var direction = SortDirection.ascending
  var query: String?
  var accountIds: [String]?
  // Reminder criteria.
  var nameContains: String?
  var listIds: [String]?
  var hasDueDate: Bool?
  var completed: Bool?
  var priorities: [Int]?
  var dueStatus: DueStatus?
  var dueFrom: String?
  var dueOnOrAfter: String?
  var dueBefore: String?
  // List criteria.
  var allowsContentModifications: Bool?
  var subscribed: Bool?

  // Matching reminders in the requested order. `scope` restricts the list IDs.
  func reminders(_ data: RemindersData, scope: Set<String>? = nil) throws -> [ReminderRecord] {
    let timestampUpper = dueBefore.flatMap { $0.contains("T") ? $0 : nil }
    let dayUpper = dueBefore.flatMap { $0.contains("T") ? nil : $0 }
    guard !(dueFrom != nil && (dueOnOrAfter != nil || dayUpper != nil)),
      !(dueOnOrAfter != nil && timestampUpper != nil)
    else {
      throw ServerError.invalidArgument("do not mix calendar-day and timestamp bounds")
    }
    try validateDays(dueOnOrAfter, dayUpper)
    let fromDate = try dueFrom.map(parseTimestamp)
    let beforeDate = try timestampUpper.map(parseTimestamp)
    if let fromDate, let beforeDate, fromDate >= beforeDate {
      throw ServerError.invalidArgument("dueFrom must precede dueBefore")
    }
    let accountLists = accountIds.map { ids in
      Set(data.lists.filter { ids.contains($0.source.id) }.map(\.id))
    }
    let text = query?.lowercased()
    let name = nameContains?.lowercased()
    let items = data.reminders.filter { item in
      if fromDate != nil || beforeDate != nil {
        guard let date = (try? projectDate(item.dueDateComponents))?.instant,
          fromDate == nil || date >= fromDate!, beforeDate == nil || date < beforeDate!
        else { return false }
      }
      let itemName = (item.name ?? "").lowercased()
      return (accountLists == nil || accountLists!.contains(item.listId ?? ""))
        && (scope == nil || scope!.contains(item.listId ?? ""))
        && (listIds == nil || listIds!.contains(item.listId ?? ""))
        && (hasDueDate == nil || hasDueDate == (item.dueDateComponents != nil))
        && (priorities == nil || priorities!.contains(item.priority))
        && (dueStatus == nil || dueStatus == item.dueStatus)
        && (completed == nil || completed == item.completed)
        && (text == nil || text!.isEmpty || itemName.contains(text!)
          || (item.body ?? "").lowercased().contains(text!))
        && (name == nil || name!.isEmpty || itemName.contains(name!))
        && matchesDays(item.dueDay, dueOnOrAfter, dayUpper)
    }
    return try reminderOrder.map { try orderReminders(items, by: $0, direction: direction) }
      ?? items
  }

  // Matching lists, by name when ordered; `accountID` restricts to one account.
  func lists(_ data: RemindersData, accountID: String? = nil) -> [ListRecord] {
    let text = query?.lowercased()
    var items = data.lists.filter {
      (accountID == nil || $0.source.id == accountID)
        && (accountIds == nil || accountIds!.contains($0.source.id))
        && (text == nil || text!.isEmpty || $0.name.lowercased().contains(text!))
        && (allowsContentModifications == nil
          || $0.allowsContentModifications == allowsContentModifications)
        && (subscribed == nil || $0.subscribed == subscribed)
    }
    if sortListsByName {
      items.sort {
        let a = $0.name.lowercased()
        let b = $1.name.lowercased()
        return a == b ? $0.id < $1.id : direction == .descending ? a > b : a < b
      }
    }
    return items
  }
}
