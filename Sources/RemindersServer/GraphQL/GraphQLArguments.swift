import Foundation

// Typed collection arguments. GraphQL has already checked their types and filled
// defaults; decoding gives resolvers named fields instead of map lookups.

struct GraphQLReminderSearch: Decodable {
  let filter: InputField<Filter>
  let orderBy: InputField<Order>
  let limit, offset: Int

  struct Filter: Decodable, Sendable {
    let query, nameContains, dueStatus, dueOnOrAfter, dueBefore, dueFrom: InputField<String>
    let accountIds, listIds: InputField<[String]>
    let hasDueDate, completed, flagged: InputField<Bool>
    let priorities: InputField<[Int]>
    enum CodingKeys: String, CodingKey, CaseIterable {
      case query, nameContains, dueStatus, dueOnOrAfter, dueBefore, dueFrom, accountIds, listIds
      case hasDueDate, completed, flagged, priorities
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      query = try c.field(.query)
      nameContains = try c.field(.nameContains)
      dueStatus = try c.field(.dueStatus)
      dueOnOrAfter = try c.field(.dueOnOrAfter)
      dueBefore = try c.field(.dueBefore)
      dueFrom = try c.field(.dueFrom)
      accountIds = try c.field(.accountIds)
      listIds = try c.field(.listIds)
      hasDueDate = try c.field(.hasDueDate)
      completed = try c.field(.completed)
      flagged = try c.field(.flagged)
      priorities = try c.field(.priorities)
    }
  }
  struct Order: Decodable, Sendable {
    let field: String
    let direction: InputField<String>
    enum CodingKeys: String, CodingKey, CaseIterable { case field, direction }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      field = try c.decode(String.self, forKey: .field)
      direction = try c.field(.direction)
    }
  }
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, orderBy, limit, offset }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.field(.filter)
    orderBy = try c.field(.orderBy)
    limit = try c.decode(Int.self, forKey: .limit)
    offset = try c.decode(Int.self, forKey: .offset)
  }
}

struct GraphQLListSearch: Decodable {
  let filter: InputField<Filter>
  let orderBy: InputField<Order>
  let limit, offset: Int

  struct Filter: Decodable, Sendable {
    let query: InputField<String>
    let accountIds: InputField<[String]>
    let allowsContentModifications, subscribed: InputField<Bool>
    enum CodingKeys: String, CodingKey, CaseIterable {
      case query, accountIds, allowsContentModifications, subscribed
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      query = try c.field(.query)
      accountIds = try c.field(.accountIds)
      allowsContentModifications = try c.field(.allowsContentModifications)
      subscribed = try c.field(.subscribed)
    }
  }
  struct Order: Decodable, Sendable {
    let direction: InputField<String>
    enum CodingKeys: String, CodingKey, CaseIterable { case direction }
    init(from decoder: Decoder) throws {
      direction = try decoder.inputContainer(keyedBy: CodingKeys.self).field(.direction)
    }
  }
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, orderBy, limit, offset }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.field(.filter)
    orderBy = try c.field(.orderBy)
    limit = try c.decode(Int.self, forKey: .limit)
    offset = try c.decode(Int.self, forKey: .offset)
  }
}

// Mutation arguments.

struct GraphQLIDArguments: Decodable {
  let id: String
  enum CodingKeys: String, CodingKey, CaseIterable { case id }
  init(from decoder: Decoder) throws {
    id = try decoder.inputContainer(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
  }
}

struct GraphQLCreateArguments<Input: Decodable>: Decodable {
  let input: Input
  enum CodingKeys: String, CodingKey, CaseIterable { case input }
  init(from decoder: Decoder) throws {
    input = try decoder.inputContainer(keyedBy: CodingKeys.self).decode(Input.self, forKey: .input)
  }
}

struct GraphQLPatchArguments<Patch: Decodable>: Decodable {
  let id: String
  let patch: Patch
  enum CodingKeys: String, CodingKey, CaseIterable { case id, patch }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    patch = try c.decode(Patch.self, forKey: .patch)
  }
}

struct GraphQLListDeleteArguments: Decodable {
  let id: String
  let allowNonEmpty: Bool
  enum CodingKeys: String, CodingKey, CaseIterable { case id, allowNonEmpty }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    allowNonEmpty = try c.decode(Bool.self, forKey: .allowNonEmpty)
  }
}

struct GraphQLClearCompletedArguments: Decodable {
  let listId: String
  enum CodingKeys: String, CodingKey, CaseIterable { case listId }
  init(from decoder: Decoder) throws {
    listId = try decoder.inputContainer(keyedBy: CodingKeys.self).decode(
      String.self, forKey: .listId)
  }
}
