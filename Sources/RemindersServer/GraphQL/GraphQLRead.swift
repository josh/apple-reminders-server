import Foundation
import GraphQL

func calendarField(
  _ type: GraphQLOutputType, _ components: KeyPath<ReminderRecord, ComponentDate?> & Sendable,
  timed: Bool, description: String
) -> GraphQLField {
  field(
    type,
    { (item: ReminderRecord) -> String? in
      guard let date = try projectDate(item[keyPath: components]), date.timed == timed else {
        return nil
      }
      return timed ? timestamp(date.instant) : date.day
    }, description: description)
}

func listSearchPage(_ data: RemindersData, args: Map, accountID: String? = nil) throws
  -> GraphQLPage<ListRecord>
{
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
