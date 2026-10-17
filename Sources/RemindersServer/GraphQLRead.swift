import Foundation
import GraphQL

func componentValue(_ source: Map, key: String) throws -> ComponentDate? {
  guard source[key] != .null && source[key] != .undefined else { return nil }
  return try JSONDecoder().decode(ComponentDate.self, from: JSONEncoder().encode(source[key]))
}
func calendarField(_ type: GraphQLOutputType, key: String, timed: Bool) -> GraphQLField {
  GraphQLField(
    type: type,
    resolve: { source, _, _, _ in
      guard let source = source as? Map,
        let date = try projectDate(componentValue(source, key: key)), date.timed == timed
      else { return nil }
      return timed ? timestamp(date.instant) : date.day
    })
}

func listSearchPage(_ data: Inventory, args: Map, accountID: String? = nil) throws -> Map {
  let filter = args["filter"]
  let query = try? filter["query"].stringValue().lowercased()
  let accounts = try? filter["accountIds"].arrayValue().map { try $0.stringValue() }
  let editable = try? filter["allowsContentModifications"].boolValue()
  let subscribed = try? filter["subscribed"].boolValue()
  var items = data.lists.filter {
    (accountID == nil || $0.source.id == accountID)
      && (accounts == nil || accounts!.contains($0.source.id))
      && (query == nil || $0.name.lowercased().contains(query!))
      && (editable == nil || $0.allowsContentModifications == editable)
      && (subscribed == nil || $0.isSubscribed == subscribed)
  }
  if args["orderBy"] != .null && args["orderBy"] != .undefined {
    let descending = (try? args["orderBy"]["direction"].stringValue()) == "DESC"
    items.sort {
      let a = $0.name.lowercased()
      let b = $1.name.lowercased()
      return a == b ? $0.id < $1.id : descending ? a > b : a < b
    }
  }
  return try page(graphMaps(items), args: args)
}

func orderedReminders(_ items: [ReminderRecord], args: Map) throws -> [ReminderRecord] {
  guard args["orderBy"] != .null && args["orderBy"] != .undefined else {
    return items
  }
  let field = try args["orderBy"]["field"].stringValue()
  let descending = (try? args["orderBy"]["direction"].stringValue()) == "DESC"
  return try orderReminders(items, field: field, descending: descending)
}

func recurrenceProjection(_ source: Map) throws -> Map? {
  let rules = try JSONDecoder().decode(
    [RecurrenceRecord].self, from: JSONEncoder().encode(source["recurrenceRules"]))
  return try recurrenceView(rules).map(graphMap)
}
func alarmProjections(_ source: Map) throws -> [Map] {
  let alarms = try JSONDecoder().decode(
    [AlarmRecord].self, from: JSONEncoder().encode(source["alarms"]))
  return try alarms.map { alarm in
    let view = try AlarmView(alarm)
    var result = try graphMap(view)
    result["__typename"] = Map(view.kind)
    return result
  }
}
