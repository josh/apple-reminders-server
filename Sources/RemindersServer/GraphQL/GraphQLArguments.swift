import Foundation

// Typed collection arguments. GraphQL has already checked their types and filled
// defaults; decoding gives resolvers named fields instead of map lookups.

struct GraphQLReminderSearch: Decodable {
  let filter: Filter?
  let orderBy: Order?
  let limit, offset: Int

  struct Filter: Decodable, Sendable {
    let query, nameContains, dueStatus, dueOnOrAfter, dueBefore, dueFrom: String?
    let completedFrom, completedBefore: String?
    let accountIds, listIds: [String]?
    let hasDueDate, completed, flagged: Bool?
    let priorities: [Int]?
  }
  struct Order: Decodable, Sendable {
    let field: ReminderSortField
    let direction: SortDirection?
  }
}

struct GraphQLListSearch: Decodable {
  let filter: Filter?
  let orderBy: Order?
  let limit, offset: Int

  struct Filter: Decodable, Sendable {
    let query: String?
    let accountIds: [String]?
    let allowsContentModifications, subscribed: Bool?
  }
  struct Order: Decodable, Sendable {
    let direction: SortDirection?
  }
}

// Mutation arguments.

struct GraphQLIDArguments: Decodable {
  let id: String
}

struct GraphQLCreateArguments<Input: Decodable>: Decodable {
  let input: Input
}

struct GraphQLPatchArguments<Patch: Decodable>: Decodable {
  let id: String
  let patch: Patch
}

struct GraphQLListDeleteArguments: Decodable {
  let id: String
  let allowNonEmpty: Bool
}

struct GraphQLClearCompletedArguments: Decodable {
  let listId: String
}
