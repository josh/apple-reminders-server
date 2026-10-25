import Foundation
import GraphQL

func componentValue(_ source: Map, key: String) throws -> ComponentDate? {
  guard source[key] != .null && source[key] != .undefined else { return nil }
  return try JSONDecoder().decode(ComponentDate.self, from: JSONEncoder().encode(source[key]))
}
func calendarField(_ type: GraphQLOutputType, key: String, timed: Bool, description: String)
  -> GraphQLField
{
  GraphQLField(
    type: type, description: description,
    resolve: { source, _, _, _ in
      guard let source = source as? Map,
        let date = try projectDate(componentValue(source, key: key)), date.timed == timed
      else { return nil }
      return timed ? timestamp(date.instant) : date.day
    })
}

func listSearchPage(_ data: RemindersData, args: Map, accountID: String? = nil) throws -> Map {
  let arguments = try decodeInput(GraphQLListSearch.self, from: args)
  var search = Search()
  if let filter = arguments.filter.value {
    search.query = filter.query.value
    search.accountIds = filter.accountIds.value
    search.allowsContentModifications = filter.allowsContentModifications.value
    search.subscribed = filter.subscribed.value
  }
  if let order = arguments.orderBy.value {
    search.sortListsByName = true
    search.descending = order.direction.value == "DESC"
  }
  return try page(
    search.lists(data, accountID: accountID), limit: arguments.limit, offset: arguments.offset)
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
