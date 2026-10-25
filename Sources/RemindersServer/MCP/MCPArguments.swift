import Foundation

// Typed tool arguments. Each rejects keys its tool does not declare. MCP rejects
// explicit nulls before decoding, so optional fields are either absent or present.

struct IDArguments: Decodable {
  let id: String
  enum CodingKeys: String, CodingKey, CaseIterable { case id }
  init(from decoder: Decoder) throws {
    id = try decoder.inputContainer(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
  }
}

struct PatchArguments<Patch: Decodable>: Decodable {
  let id: String
  let patch: Patch
  enum CodingKeys: String, CodingKey, CaseIterable { case id, patch }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
    patch = try c.decode(Patch.self, forKey: .patch)
  }
}

struct ListDeleteArguments: Decodable {
  let id: String
  let allowNonEmpty: InputField<Bool>
  enum CodingKeys: String, CodingKey, CaseIterable { case id, allowNonEmpty }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
    allowNonEmpty = try c.field(.allowNonEmpty)
  }
}

struct SummaryArguments: Decodable {
  let listId: InputField<String>
  enum CodingKeys: String, CodingKey, CaseIterable { case listId }
  init(from decoder: Decoder) throws {
    listId = try decoder.inputContainer(keyedBy: CodingKeys.self).field(.listId)
    guard listId.value != "" else { throw ServerError.invalidArgument("listId must not be empty") }
  }
}

struct ListSearchArguments: Decodable {
  let filter: InputField<Filter>
  let orderBy: InputField<Order>
  let limit: InputField<Int>
  let cursor: InputField<String>

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
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, orderBy, limit, cursor }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.field(.filter)
    orderBy = try c.field(.orderBy)
    limit = try c.field(.limit)
    cursor = try c.field(.cursor)
  }
}

struct ReminderSearchArguments: Decodable {
  let filter: InputField<Filter>
  let orderBy: InputField<Order>
  let limit: InputField<Int>
  let cursor: InputField<String>

  struct Filter: Decodable, Sendable {
    let accountIds, listIds: InputField<[String]>
    let query, dueFrom, dueBefore, dueOnOrAfter, dueStatus: InputField<String>
    let completed, hasDueDate: InputField<Bool>
    let priorities: InputField<[Int]>
    enum CodingKeys: String, CodingKey, CaseIterable {
      case accountIds, listIds, query, dueFrom, dueBefore, dueOnOrAfter, dueStatus, completed
      case hasDueDate, priorities
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      accountIds = try c.field(.accountIds)
      listIds = try c.field(.listIds)
      query = try c.field(.query)
      dueFrom = try c.field(.dueFrom)
      dueBefore = try c.field(.dueBefore)
      dueOnOrAfter = try c.field(.dueOnOrAfter)
      dueStatus = try c.field(.dueStatus)
      completed = try c.field(.completed)
      hasDueDate = try c.field(.hasDueDate)
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
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, orderBy, limit, cursor }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.field(.filter)
    orderBy = try c.field(.orderBy)
    limit = try c.field(.limit)
    cursor = try c.field(.cursor)
  }
}
