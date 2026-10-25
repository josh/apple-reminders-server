import Foundation

// Typed tool arguments. Each rejects keys its tool does not declare. MCP rejects
// explicit nulls before decoding, so optional fields are plain optionals.

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
  let allowNonEmpty: Bool?
  enum CodingKeys: String, CodingKey, CaseIterable { case id, allowNonEmpty }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
    allowNonEmpty = try c.decodeIfPresent(Bool.self, forKey: .allowNonEmpty)
  }
}

struct SummaryArguments: Decodable {
  let listId: String?
  enum CodingKeys: String, CodingKey, CaseIterable { case listId }
  init(from decoder: Decoder) throws {
    listId = try decoder.inputContainer(keyedBy: CodingKeys.self).decodeIfPresent(
      String.self, forKey: .listId)
    guard listId != "" else { throw ServerError.invalidArgument("listId must not be empty") }
  }
}

struct ListSearchArguments: Decodable {
  let filter: Filter?
  let orderBy: Order?
  let limit: Int?
  let cursor: String?

  struct Filter: Decodable, Sendable {
    let query: String?
    let accountIds: [String]?
    let allowsContentModifications, subscribed: Bool?
    enum CodingKeys: String, CodingKey, CaseIterable {
      case query, accountIds, allowsContentModifications, subscribed
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      query = try c.decodeIfPresent(String.self, forKey: .query)
      accountIds = try c.decodeIfPresent([String].self, forKey: .accountIds)
      allowsContentModifications = try c.decodeIfPresent(
        Bool.self, forKey: .allowsContentModifications)
      subscribed = try c.decodeIfPresent(Bool.self, forKey: .subscribed)
    }
  }
  struct Order: Decodable, Sendable {
    let direction: SortDirection?
    enum CodingKeys: String, CodingKey, CaseIterable { case direction }
    init(from decoder: Decoder) throws {
      direction = try decoder.inputContainer(keyedBy: CodingKeys.self).decodeIfPresent(
        SortDirection.self, forKey: .direction)
    }
  }
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, orderBy, limit, cursor }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.decodeIfPresent(Filter.self, forKey: .filter)
    orderBy = try c.decodeIfPresent(Order.self, forKey: .orderBy)
    limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
  }
}

struct ReminderSearchArguments: Decodable {
  let filter: Filter?
  let orderBy: Order?
  let limit: Int?
  let cursor: String?

  struct Filter: Decodable, Sendable {
    let accountIds, listIds: [String]?
    let query, dueFrom, dueBefore, dueOnOrAfter: String?
    let dueStatus: DueStatus?
    let completed, hasDueDate: Bool?
    let priorities: [Int]?
    enum CodingKeys: String, CodingKey, CaseIterable {
      case accountIds, listIds, query, dueFrom, dueBefore, dueOnOrAfter, dueStatus, completed
      case hasDueDate, priorities
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      accountIds = try c.decodeIfPresent([String].self, forKey: .accountIds)
      listIds = try c.decodeIfPresent([String].self, forKey: .listIds)
      query = try c.decodeIfPresent(String.self, forKey: .query)
      dueFrom = try c.decodeIfPresent(String.self, forKey: .dueFrom)
      dueBefore = try c.decodeIfPresent(String.self, forKey: .dueBefore)
      dueOnOrAfter = try c.decodeIfPresent(String.self, forKey: .dueOnOrAfter)
      dueStatus = try c.decodeIfPresent(DueStatus.self, forKey: .dueStatus)
      completed = try c.decodeIfPresent(Bool.self, forKey: .completed)
      hasDueDate = try c.decodeIfPresent(Bool.self, forKey: .hasDueDate)
      priorities = try c.decodeIfPresent([Int].self, forKey: .priorities)
    }
  }
  struct Order: Decodable, Sendable {
    let field: ReminderSortField
    let direction: SortDirection?
    enum CodingKeys: String, CodingKey, CaseIterable { case field, direction }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      field = try c.decode(ReminderSortField.self, forKey: .field)
      direction = try c.decodeIfPresent(SortDirection.self, forKey: .direction)
    }
  }
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, orderBy, limit, cursor }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.decodeIfPresent(Filter.self, forKey: .filter)
    orderBy = try c.decodeIfPresent(Order.self, forKey: .orderBy)
    limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
  }
}
