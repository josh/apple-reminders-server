import Foundation
import MCP

private struct Search: Codable, Equatable, Sendable {
  var resource: String = "reminders"
  var orderField: String?
  var descending: Bool = false
  var dueFrom: String?
  var accountIds: [String]?
  var listIds: [String]?
  var flagged: Bool?
  var hasDueDate: Bool?
  var allowsContentModifications: Bool?
  var subscribed: Bool?
  var completed: Bool?
  var query: String?
  var limit: Int = 50
  var priorities: [Int]?
  var dueStatus: DueStatus?
  var dueOnOrAfter: String?
  var dueBefore: String?
}
private struct Cursor {
  let search: Search
  let offset: Int
  let expires: Date
}
private actor CursorStore {
  private var cursors: [String: Cursor] = [:]
  func offset(token: String?, search: Search) throws -> Int {
    cursors = cursors.filter { $0.value.expires > Date() }
    guard let token else { return 0 }
    guard let cursor = cursors[token], cursor.search == search else {
      throw ServerError.message(
        "INVALID_ARGUMENT: Invalid/expired cursor or changed search criteria")
    }
    return cursor.offset
  }
  func insert(search: Search, offset: Int) -> String {
    if cursors.count >= 1024,
      let oldest = cursors.min(by: { $0.value.expires < $1.value.expires })?.key
    {
      cursors.removeValue(forKey: oldest)
    }
    let token = UUID().uuidString
    cursors[token] = Cursor(
      search: search, offset: offset, expires: Date(timeIntervalSinceNow: 600))
    return token
  }
}
private let cursors = CursorStore()
private struct SearchOutput: Encodable {
  let items: [MCPReminder]
  let totalCount: Int
  let nextCursor: String?
}
private struct ListsOutput: Encodable {
  let items: [MCPList]
  let totalCount: Int
  let nextCursor: String?
}
private struct AccountOutput: Encodable {
  let account: AccountRecord?
  enum CodingKeys: CodingKey { case account }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(account, forKey: .account)
  }
}
private struct AccountsOutput: Encodable { let items: [AccountRecord] }
private struct SummaryOutput: Encodable { let items: [ListSummary] }
private struct ListOutput: Encodable {
  let list: MCPList?
  enum CodingKeys: CodingKey { case list }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(list, forKey: .list)
  }
}
private struct DefaultsOutput: Encodable {
  let list: MCPList?
  let account: AccountRecord?
  enum CodingKeys: CodingKey { case list, account }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(list, forKey: .list)
    try c.encode(account, forKey: .account)
  }
}
private struct GetOutput: Encodable {
  let reminder: MCPReminder?
  enum CodingKeys: CodingKey { case reminder }
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(reminder, forKey: .reminder)
  }
}
private func schema(_ properties: [String: Value], required: [String] = []) -> Value {
  .object([
    "type": "object", "properties": .object(properties),
    "required": .array(required.map(Value.string)), "additionalProperties": false,
  ])
}
private func primitive(_ type: String, nullable: Bool = false) -> Value {
  .object(["type": nullable ? .array([.string(type), "null"]) : .string(type)])
}
private func array(_ item: Value) -> Value { .object(["type": "array", "items": item]) }
private func enumeration(_ values: [String]) -> Value {
  .object(["type": "string", "enum": .array(values.map(Value.string))])
}
private let reminderFilterKeys: Set<String> = [
  "accountIds", "listIds", "query", "completed", "flagged", "priorities", "hasDueDate",
  "dueFrom", "dueBefore", "dueOnOrAfter", "dueStatus",
]
private let listFilterKeys: Set<String> = [
  "query", "accountIds", "allowsContentModifications", "subscribed",
]
private func nullable(_ value: Value) -> Value {
  .object(["anyOf": .array([value, primitive("null")])])
}
private func toolsCatalog() -> [Tool] {
  var parts = Dictionary(
    uniqueKeysWithValues: [
      "era", "year", "month", "day", "hour", "minute", "second", "nanosecond", "weekday",
      "weekdayOrdinal", "quarter", "weekOfMonth", "weekOfYear", "yearForWeekOfYear",
    ].map { ($0, primitive("integer")) })
  parts["calendar"] = primitive("string")
  parts["timeZone"] = primitive("string")
  parts["isLeapMonth"] = primitive("boolean")
  var reminder = Dictionary(
    uniqueKeysWithValues: [
      "id", "externalId", "listId", "name", "body", "creationDate", "completionDate",
      "modificationDate", "location", "url",
    ].map { ($0, primitive("string")) })
  for name in ["dueDate", "allDayDueDate", "startDate", "allDayStartDate", "timeZone"] {
    reminder[name] = primitive("string", nullable: true)
  }
  reminder["dueDay"] = primitive("string", nullable: true)
  reminder["flagged"] = primitive("boolean", nullable: true)
  reminder["completed"] = primitive("boolean")
  reminder["priority"] = primitive("integer")
  reminder["startDateComponents"] = schema(parts)
  reminder["dueDateComponents"] = schema(parts)
  reminder["dueStatus"] = enumeration(DueStatus.allCases.map(\.rawValue))
  let structuredLocation = schema(
    [
      "title": primitive("string"), "latitude": primitive("number"),
      "longitude": primitive("number"), "radius": primitive("number"),
    ], required: ["radius"])
  reminder["alarms"] = array(
    schema(
      [
        "absoluteDate": primitive("string"), "relativeOffset": primitive("number"),
        "proximity": enumeration(["none", "enter", "leave", "unknown"]),
        "structuredLocation": structuredLocation,
      ], required: ["relativeOffset", "proximity"]))
  reminder["rawAlarms"] = reminder["alarms"]
  let geofence = schema(
    [
      "title": primitive("string"), "latitude": primitive("number"),
      "longitude": primitive("number"), "radiusMeters": primitive("number"),
      "proximity": enumeration(["ARRIVE", "DEPART"]),
    ], required: ["latitude", "longitude", "radiusMeters", "proximity"])
  reminder["alarms"] = array(
    .object([
      "oneOf": .array([
        schema(
          ["kind": enumeration(["AbsoluteAlarm"]), "at": primitive("string")],
          required: ["kind", "at"]),
        schema(
          ["kind": enumeration(["RelativeAlarm"]), "offsetSeconds": primitive("number")],
          required: ["kind", "offsetSeconds"]),
        schema(
          ["kind": enumeration(["LocationAlarm"]), "geofence": geofence],
          required: ["kind", "geofence"]),
      ])
    ]))
  let reference = schema(
    ["kind": enumeration(["ReminderList", "Reminder"]), "id": primitive("string")],
    required: ["kind", "id"])
  reminder["container"] = reference
  reminder["remindMeDate"] = primitive("string", nullable: true)
  var schedule: [String: Value] = [
    "frequency": enumeration(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]),
    "interval": primitive("integer"),
    "daysOfWeek": array(
      schema(
        [
          "day": enumeration([
            "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY",
          ]), "ordinal": primitive("integer"),
        ], required: ["day"])),
    "end": schema(["until": primitive("string"), "count": primitive("integer")]),
  ]
  for name in ["daysOfMonth", "monthsOfYear", "weeksOfYear", "daysOfYear", "setPositions"] {
    schedule[name] = array(primitive("integer"))
  }
  reminder["recurrence"] = nullable(schema(schedule, required: ["frequency", "interval"]))
  var recurrence: [String: Value] = [
    "frequency": enumeration(["daily", "weekly", "monthly", "yearly", "unknown"]),
    "calendarIdentifier": primitive("string"), "interval": primitive("integer"),
    "firstDayOfTheWeek": primitive("integer"),
    "daysOfTheWeek": array(
      schema(
        ["dayOfTheWeek": primitive("integer"), "weekNumber": primitive("integer")],
        required: ["dayOfTheWeek", "weekNumber"])),
    "end": schema(
      ["endDate": primitive("string"), "occurrenceCount": primitive("integer")],
      required: ["occurrenceCount"]),
  ]
  for name in [
    "daysOfTheMonth", "daysOfTheYear", "weeksOfTheYear", "monthsOfTheYear", "setPositions",
  ] { recurrence[name] = array(primitive("integer")) }
  reminder["recurrenceRules"] = array(
    schema(
      recurrence,
      required: [
        "frequency", "calendarIdentifier", "interval", "firstDayOfTheWeek", "daysOfTheWeek",
        "daysOfTheMonth", "daysOfTheYear", "weeksOfTheYear", "monthsOfTheYear", "setPositions",
      ]))
  let item = schema(
    reminder,
    required: [
      "container", "remindMeDate", "rawAlarms", "recurrence", "dueDate", "allDayDueDate",
      "startDate", "allDayStartDate", "timeZone", "id", "completed", "priority", "dueDay",
      "flagged", "dueStatus", "alarms", "recurrenceRules",
    ])
  let list = schema(
    [
      "container": schema(
        ["kind": enumeration(["Account", "ReminderList"]), "id": primitive("string")],
        required: ["kind", "id"]), "emblem": primitive("string", nullable: true),
      "allowsListModifications": primitive("boolean"), "subscribed": primitive("boolean"),
      "id": primitive("string"), "name": primitive("string"), "color": primitive("string"),
      "source": schema(
        ["id": primitive("string"), "title": primitive("string"), "type": primitive("integer")],
        required: ["id", "title", "type"]), "allowsContentModifications": primitive("boolean"),
      "isImmutable": primitive("boolean"), "isSubscribed": primitive("boolean"),
    ],
    required: ["id", "name", "source", "allowsContentModifications", "isImmutable", "isSubscribed"])
  let order = schema(
    [
      "field": enumeration([
        "NAME", "DUE_DATE", "PRIORITY", "CREATION_DATE", "MODIFICATION_DATE", "COMPLETION_DATE",
      ]), "direction": enumeration(["ASC", "DESC"]),
    ], required: ["field"])
  let pagination: [String: Value] = [
    "limit": .object(["type": "integer", "minimum": 1, "maximum": 100, "default": 50]),
    "cursor": .object(["type": "string", "minLength": 1]),
  ]
  let search = schema(
    pagination.merging([
      "orderBy": order,
      "filter": schema([
        "dueFrom": primitive("string"), "accountIds": array(primitive("string")),
        "listIds": array(primitive("string")), "flagged": primitive("boolean"),
        "hasDueDate": primitive("boolean"), "dueOnOrAfter": primitive("string"),
        "dueBefore": primitive("string"),
        "priorities": array(.object(["type": "integer", "minimum": 0, "maximum": 9])),
        "dueStatus": enumeration(DueStatus.allCases.map(\.rawValue)),
        "completed": primitive("boolean"), "query": primitive("string"),
      ]),
    ]) { _, new in new })
  let listSearch = schema(
    pagination.merging([
      "filter": schema([
        "query": primitive("string"), "accountIds": array(primitive("string")),
        "allowsContentModifications": primitive("boolean"), "subscribed": primitive("boolean"),
      ]),
      "orderBy": schema(["direction": enumeration(["ASC", "DESC"])]),
    ]) { _, new in new })
  let account = schema(
    ["id": primitive("string"), "name": primitive("string")], required: ["id", "name"])
  let counts = [
    "total", "completed", "incomplete", "overdue", "scheduled", "recurring", "withAlarms",
  ]
  var summary = Dictionary(uniqueKeysWithValues: counts.map { ($0, primitive("integer")) })
  summary["listId"] = primitive("string")
  let annotations = Tool.Annotations(
    readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  let alarmInput = schema([
    "absoluteDate": primitive("string"), "relativeOffsetSeconds": primitive("number"),
    "geofence": schema(
      [
        "title": primitive("string"),
        "latitude": .object(["type": "number", "minimum": -90, "maximum": 90]),
        "longitude": .object(["type": "number", "minimum": -180, "maximum": 180]),
        "radiusMeters": .object(["type": "number", "minimum": 0]),
        "proximity": enumeration(["ARRIVE", "DEPART"]),
      ], required: ["latitude", "longitude", "radiusMeters", "proximity"]),
  ])
  var writeFields = Dictionary(
    uniqueKeysWithValues: [
      "name", "body", "location", "url", "dueDate", "allDayDueDate", "startDate", "allDayStartDate",
    ].map { ($0, primitive("string")) })
  writeFields["priority"] = .object(["type": "integer", "minimum": 0, "maximum": 9])
  writeFields["alarms"] = array(alarmInput)
  writeFields["timeZone"] = primitive("string")
  writeFields["flagged"] = primitive("boolean")
  writeFields["remindMeDate"] = primitive("string")
  writeFields["recurrence"] = schema(schedule, required: ["frequency", "interval"])
  var createFields = writeFields
  createFields["listId"] = primitive("string")
  writeFields["completed"] = primitive("boolean")
  writeFields["completionDate"] = primitive("string")
  writeFields["clearFields"] = array(enumeration(ReminderClearValue.allCases.map(\.rawValue)))
  let created = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
  let changed = Tool.Annotations(
    readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
  let listPatch = schema([
    "name": primitive("string"), "color": primitive("string"), "emblem": primitive("string"),
  ])
  let listCreate = schema(
    [
      "name": primitive("string"), "accountId": primitive("string"), "color": primitive("string"),
      "emblem": primitive("string"),
    ], required: ["name", "accountId"])
  let navigation = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  return [
    Tool(
      name: "lists_create",
      description:
        "Create a list in an explicit account. Colors use opaque #RRGGBB or #RRGGBBFF. Emblems are Reminders icon names. WRITE_APPLIED includes the saved ID if subsequent automation or enrichment fails; do not retry creation blindly.",
      inputSchema: listCreate, annotations: created,
      outputSchema: schema(["list": list], required: ["list"])),
    Tool(
      name: "lists_update",
      description:
        "Update list name, color or emblem. Omitted values are unchanged; nulls and empty patches are invalid. Emblem writes or response enrichment can fail after stored fields are saved. WRITE_APPLIED includes the saved ID; refetch before retrying.",
      inputSchema: schema(
        ["id": primitive("string"), "patch": listPatch], required: ["id", "patch"]),
      annotations: changed, outputSchema: schema(["list": list], required: ["list"])),
    Tool(
      name: "lists_delete",
      description:
        "Delete a list. Nonempty lists require allowNonEmpty=true, which also deletes their reminders. The emptiness check does not lock out concurrent external edits.",
      inputSchema: schema(
        [
          "id": primitive("string"),
          "allowNonEmpty": .object(["type": "boolean", "default": false]),
        ], required: ["id"]), annotations: changed,
      outputSchema: schema(["deletedId": primitive("string")], required: ["deletedId"])),
    Tool(
      name: "reminders_show",
      description: "Show a reminder in Reminders. Changes the application UI, not reminder data.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: navigation,
      outputSchema: schema(["reminder": item], required: ["reminder"])),
    Tool(
      name: "lists_show",
      description: "Show a list in Reminders. Changes the application UI, not list data.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: navigation,
      outputSchema: schema(["list": list], required: ["list"])),
    Tool(
      name: "reminders_create",
      description:
        "Create an incomplete reminder. Specify listId or use the application's default list. Optional values must be omitted, not null. Timed/all-day due dates are exclusive; allDayStartDate is currently unsupported. Each alarm needs exactly one trigger; relative alarms require a start date. A retry can create duplicates. A WRITE_APPLIED error means the save succeeded but later automation or response enrichment failed; refetch using the reported ID.",
      inputSchema: schema(createFields, required: ["name"]), annotations: created,
      outputSchema: schema(["reminder": item], required: ["reminder"])),
    Tool(
      name: "reminders_update",
      description:
        "Patch a reminder by ID. Omitted fields are unchanged; null is invalid. At least one change is required. clearFields removes optional values; [] alone is not a change. Do not set and clear a property together, or combine completed and completionDate changes. alarms replaces all alerts; [] removes them. Dates can affect alerts. A WRITE_APPLIED error means the save succeeded but later automation or response enrichment failed; refetch before retrying.",
      inputSchema: schema(
        ["id": primitive("string"), "patch": schema(writeFields)], required: ["id", "patch"]),
      annotations: changed, outputSchema: schema(["reminder": item], required: ["reminder"])),
    Tool(
      name: "reminders_delete",
      description:
        "Delete one reminder. Missing IDs return a NOT_FOUND tool error. Refetch before retrying after uncertain failures.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: changed,
      outputSchema: schema(["deletedId": primitive("string")], required: ["deletedId"])),
    Tool(
      name: "accounts_get",
      description:
        "Read an account by identifier; returns null when it has no accessible reminder lists or is absent.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: annotations,
      outputSchema: schema(["account": nullable(account)], required: ["account"])),
    Tool(
      name: "accounts_list",
      description: "Read accounts with accessible reminder lists, ordered by identifier.",
      inputSchema: schema([:]), annotations: annotations,
      outputSchema: schema(["items": array(account)], required: ["items"])),
    Tool(
      name: "lists_get",
      description:
        "Read a list with its icon and container reference; absent identifiers return null. Reminders automation metadata is required for a complete result.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: annotations,
      outputSchema: schema(["list": nullable(list)], required: ["list"])),
    Tool(
      name: "defaults_get",
      description:
        "Read the accessible default list and its account; unavailable defaults return null.",
      inputSchema: schema([:]), annotations: annotations,
      outputSchema: schema(
        ["list": nullable(list), "account": nullable(account)], required: ["list", "account"])),
    Tool(
      name: "lists_summary",
      description:
        "Count all reminders per accessible list, optionally restricted to listId. Counts overlap and include completed items except overdue.",
      inputSchema: schema(["listId": primitive("string")]), annotations: annotations,
      outputSchema: schema(
        ["items": array(schema(summary, required: counts + ["listId"]))], required: ["items"])),
    Tool(
      name: "lists_list",
      description:
        "Read lists filtered by name, account IDs, editability, and subscription. Use filter for search criteria. orderBy.direction selects name ordering; omission uses identifier order. Filters intersect. Pagination uses limit and an opaque cursor tied to unchanged criteria. Name ordering is case-insensitive with ID ascending ties.",
      inputSchema: listSearch, annotations: annotations,
      outputSchema: schema(
        [
          "items": array(list), "totalCount": primitive("integer"),
          "nextCursor": primitive("string"),
        ], required: ["items", "totalCount"])),
    Tool(
      name: "reminders_search",
      description:
        "Read reminders filtered by account/list IDs, completion, flags, deadline presence, numeric priorities, due status and case-insensitive name-or-notes substring. Filters intersect; empty ID arrays match nothing. Supply criteria in filter. dueFrom and timestamp dueBefore bound deadline instants (inclusive/exclusive). All-day deadlines use midnight in their source zone. Calendar-day dueOnOrAfter and date-only dueBefore use reporting days; do not mix bound modes. orderBy supports NAME, DUE_DATE, PRIORITY, CREATION_DATE, MODIFICATION_DATE, COMPLETION_DATE with ASC/DESC, nulls last, and ID ascending ties. Omitted orderBy uses identifier order; priorities use numeric order. Cursor is opaque, expires after 10 minutes, and requires identical criteria and limit. Optional unavailable values are omitted. Dates retain EventKit components; omitted hours mean date-only and omitted zones mean floating.",
      inputSchema: search, annotations: annotations,
      outputSchema: schema(
        [
          "items": array(item), "totalCount": primitive("integer"),
          "nextCursor": primitive("string"),
        ], required: ["items", "totalCount"])),
    Tool(
      name: "reminders_get",
      description:
        "Read one reminder with component and projected dates, Reminders flags, container reference, alert date, alarms and recurrence; returns null when absent. Metadata read failures fail the call.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: annotations,
      outputSchema: schema(
        ["reminder": .object(["anyOf": .array([item, primitive("null")])])], required: ["reminder"])
    ),
  ]
}
private func result<T: Encodable>(_ value: T) throws -> CallTool.Result {
  let bytes = try JSONEncoder().encode(value)
  return try .init(
    content: [.text(text: String(decoding: bytes, as: UTF8.self), annotations: nil, _meta: nil)],
    structuredContent: try JSONDecoder().decode(Value.self, from: bytes), isError: false)
}
private func callTool(_ params: CallTool.Parameters) async throws -> CallTool.Result {
  let args = params.arguments ?? [:]
  func filters(_ allowed: Set<String>) throws -> [String: Value] {
    guard let value = args["filter"] else { return [:] }
    guard case .object(let filter) = value, Set(filter.keys).isSubset(of: allowed) else {
      throw ServerError.message("INVALID_ARGUMENT: filter must be an object with known fields")
    }
    return filter
  }
  func keys(_ allowed: Set<String>) throws {
    guard Set(args.keys).isSubset(of: allowed) else {
      throw ServerError.message("INVALID_ARGUMENT: Unknown argument")
    }
  }
  func string(_ key: String, from values: [String: Value]? = nil) throws -> String? {
    guard let value = (values ?? args)[key] else { return nil }
    guard let text = value.stringValue else {
      throw ServerError.message("INVALID_ARGUMENT: \(key) must be a string")
    }
    return text
  }
  func bool(_ key: String, from values: [String: Value]? = nil) throws -> Bool? {
    guard let value = (values ?? args)[key] else { return nil }
    guard case .bool(let result) = value else {
      throw ServerError.message("INVALID_ARGUMENT: \(key) must be boolean")
    }
    return result
  }
  func ids(_ key: String, from values: [String: Value]? = nil) throws -> [String]? {
    guard let value = (values ?? args)[key] else { return nil }
    guard case .array(let values) = value else {
      throw ServerError.message("INVALID_ARGUMENT: \(key) must be an array")
    }
    return try values.map { value in
      guard case .string(let id) = value, !id.isEmpty else {
        throw ServerError.message("INVALID_ARGUMENT: \(key) must contain nonempty identifiers")
      }
      return id
    }
  }
  func limit() throws -> Int {
    guard let value = args["limit"] else { return 50 }
    guard case .int(let number) = value, (1...100).contains(number) else {
      throw ServerError.message("INVALID_ARGUMENT: limit must be 1...100")
    }
    return number
  }
  switch params.name {
  case "reminders_create", "reminders_update":
    let input: MutationInput
    let request: ReminderMutation
    if params.name == "reminders_create" {
      input = try mutationInput(args)
      try input.rejectNulls()
      let changes = try reminderChanges(input, creating: true)
      request = .create(listID: try string("listId"), changes: changes)
    } else {
      try keys(["id", "patch"])
      guard let id = try string("id"), !id.isEmpty, let patch = args["patch"] else {
        throw ServerError.message("INVALID_ARGUMENT: id and patch required")
      }
      input = try mutationInput(patch)
      try input.rejectNulls()
      request = .update(id: id, changes: try reminderChanges(input, creating: false))
    }
    let saved = try await mutateReminder(request).savedRecord()
    do {
      guard let refreshed = try await readReminders().first(where: { $0.id == saved.id }) else {
        throw ServerError.message("saved reminder is not yet visible")
      }
      return try result(GetOutput(reminder: await mcpReminders([refreshed]).first))
    } catch {
      throw ServerError.message(
        "WRITE_APPLIED: reminder \(saved.id) was saved, but response enrichment failed: \(error). Refetch before retrying."
      )
    }
  case "lists_create", "lists_update":
    let request: ListMutation
    if params.name == "lists_create" {
      let input = try mutationInput(Value.object(args))
      try input.rejectNulls()
      request = .create(
        accountID: try input["accountId"].stringValue(),
        changes: try listChanges(input, creating: true))
    } else {
      try keys(["id", "patch"])
      guard let id = try string("id"), !id.isEmpty, let value = args["patch"] else {
        throw ServerError.message("INVALID_ARGUMENT: id and patch required")
      }
      let input = try mutationInput(value)
      try input.rejectNulls()
      request = .update(id: id, changes: try listChanges(input, creating: false))
    }
    let saved = try await mutateList(request).savedRecord()
    do { return try result(ListOutput(list: await mcpLists([saved]).first)) } catch {
      throw ServerError.message(
        "WRITE_APPLIED: list \(saved.id) was saved, but response enrichment failed: \(error). Refetch before retrying"
      )
    }
  case "lists_delete":
    try keys(["id", "allowNonEmpty"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.message("INVALID_ARGUMENT: id required")
    }
    let deleted = try await mutateList(
      .delete(id: id, allowNonEmpty: try bool("allowNonEmpty") ?? false)
    ).deletion()
    return try result(deleted)
  case "reminders_show":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.message("INVALID_ARGUMENT: id required")
    }
    guard case .reminder(let shown) = try await showRemindersObject(id, isList: false) else {
      throw ServerError.message("Expected a reminder")
    }
    do {
      guard let refreshed = try await readReminders().first(where: { $0.id == shown.id }) else {
        throw ServerError.message("shown reminder is unavailable")
      }
      return try result(GetOutput(reminder: await mcpReminders([refreshed]).first))
    } catch {
      throw ServerError.message(
        "SHOW_APPLIED: reminder \(id) was shown, but response enrichment failed: \(error)")
    }
  case "lists_show":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.message("INVALID_ARGUMENT: id required")
    }
    guard case .list(let shown) = try await showRemindersObject(id, isList: true) else {
      throw ServerError.message("Expected a list")
    }
    do { return try result(ListOutput(list: await mcpLists([shown]).first)) } catch {
      throw ServerError.message(
        "SHOW_APPLIED: list \(id) was shown, but response enrichment failed: \(error)")
    }
  case "reminders_delete":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.message("INVALID_ARGUMENT: id required")
    }
    let deleted = try await mutateReminder(.delete(id: id)).deletion()
    return try result(deleted)
  case "accounts_get":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.message("INVALID_ARGUMENT: id required")
    }
    return try result(AccountOutput(account: await readInventory().accounts.first { $0.id == id }))
  case "lists_list":
    try keys(["filter", "orderBy", "limit", "cursor"])
    let filter = try filters(listFilterKeys)
    var search = Search()
    search.resource = "lists"
    search.query = try string("query", from: filter)
    search.accountIds = try ids("accountIds", from: filter)
    search.allowsContentModifications = try bool("allowsContentModifications", from: filter)
    search.subscribed = try bool("subscribed", from: filter)
    search.limit = try limit()
    if let rawOrder = args["orderBy"] {
      let order = try mutationInput(rawOrder)
      try order.rejectNulls()
      try order.checkKeys(["direction"])
      let direction =
        order["direction"] == .undefined ? "ASC" : try order["direction"].stringValue()
      guard ["ASC", "DESC"].contains(direction) else {
        throw ServerError.message("INVALID_ARGUMENT: invalid list order direction")
      }
      search.orderField = "NAME"
      search.descending = direction == "DESC"
    }
    let offset = try await cursors.offset(token: string("cursor"), search: search)
    var lists = try await readInventory().lists.filter {
      (search.query == nil || $0.name.lowercased().contains(search.query!.lowercased()))
        && (search.accountIds == nil || search.accountIds!.contains($0.source.id))
        && (search.subscribed == nil || search.subscribed == $0.isSubscribed)
        && (search.allowsContentModifications == nil
          || search.allowsContentModifications == $0.allowsContentModifications)
    }
    if search.orderField != nil {
      lists.sort { a, b in
        let x = a.name.lowercased()
        let y = b.name.lowercased()
        return x == y ? a.id < b.id : search.descending ? x > y : x < y
      }
    }
    let start = min(offset, lists.count)
    let end = min(start + search.limit, lists.count)
    let token = end < lists.count ? await cursors.insert(search: search, offset: end) : nil
    return try result(
      ListsOutput(
        items: await mcpLists(Array(lists[start..<end])), totalCount: lists.count, nextCursor: token
      ))
  case "accounts_list":
    try keys([])
    return try result(AccountsOutput(items: await readInventory().accounts))
  case "lists_get":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.message("INVALID_ARGUMENT: id required")
    }
    let records = try await readInventory().lists.filter { $0.id == id }
    return try await result(ListOutput(list: mcpLists(records).first))
  case "defaults_get":
    try keys([])
    let data = try await readInventory()
    return try result(
      DefaultsOutput(
        list: await mcpLists(data.defaultList.map { [$0] } ?? []).first,
        account: data.defaultAccount))
  case "lists_summary":
    try keys(["listId"])
    let id = try string("listId")
    guard id != "" else { throw ServerError.message("INVALID_ARGUMENT: listId must not be empty") }
    let data = try await readInventory()
    return try result(
      SummaryOutput(
        items: data.lists.filter { id == nil || $0.id == id }.map {
          summarize(data, listId: $0.id)
        }))
  case "reminders_get":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.message("INVALID_ARGUMENT: id required")
    }
    let records = try await readInventory(includeFlags: true).reminders.filter { $0.id == id }
    return try await result(GetOutput(reminder: mcpReminders(records).first))
  case "reminders_search":
    try keys(["filter", "orderBy", "limit", "cursor"])
    let filter = try filters(reminderFilterKeys)
    var search = Search(
      query: try string("query", from: filter),
      dueOnOrAfter: try string("dueOnOrAfter", from: filter),
      dueBefore: try string("dueBefore", from: filter))
    search.accountIds = try ids("accountIds", from: filter)
    search.listIds = try ids("listIds", from: filter)
    search.flagged = try bool("flagged", from: filter)
    search.hasDueDate = try bool("hasDueDate", from: filter)
    search.dueFrom = try string("dueFrom", from: filter)
    let timestampUpper = search.dueBefore.flatMap { $0.contains("T") ? $0 : nil }
    let dayUpper = search.dueBefore.flatMap { $0.contains("T") ? nil : $0 }
    guard !(search.dueFrom != nil && (search.dueOnOrAfter != nil || dayUpper != nil)),
      !(search.dueOnOrAfter != nil && timestampUpper != nil)
    else {
      throw ServerError.message("INVALID_ARGUMENT: do not mix calendar-day and timestamp bounds")
    }
    try validateDays(search.dueOnOrAfter, dayUpper)
    let fromDate = try search.dueFrom.map(parseTimestamp)
    let beforeDate = try timestampUpper.map(parseTimestamp)
    if let fromDate, let beforeDate, fromDate >= beforeDate {
      throw ServerError.message("INVALID_ARGUMENT: dueFrom must precede dueBefore")
    }
    if let value = args["orderBy"] {
      let order = try mutationInput(value)
      try order.rejectNulls()
      try order.checkKeys(["field", "direction"])
      let field = try order["field"].stringValue()
      guard
        ["NAME", "DUE_DATE", "PRIORITY", "CREATION_DATE", "MODIFICATION_DATE", "COMPLETION_DATE"]
          .contains(field)
      else { throw ServerError.message("INVALID_ARGUMENT: invalid order field") }
      let direction =
        order["direction"] == .undefined ? "ASC" : try order["direction"].stringValue()
      guard ["ASC", "DESC"].contains(direction) else {
        throw ServerError.message("INVALID_ARGUMENT: invalid order direction")
      }
      search.orderField = field
      search.descending = direction == "DESC"
    }
    if let value = filter["completed"] {
      guard case .bool(let flag) = value else {
        throw ServerError.message("INVALID_ARGUMENT: completed must be boolean")
      }
      search.completed = flag
    }
    if let value = args["limit"] {
      guard case .int(let limit) = value, (1...100).contains(limit) else {
        throw ServerError.message("INVALID_ARGUMENT: limit must be 1...100")
      }
      search.limit = limit
    }
    if let value = filter["priorities"] {
      guard case .array(let values) = value else {
        throw ServerError.message("INVALID_ARGUMENT: priorities must be an integer array")
      }
      search.priorities = try values.map { value in
        guard case .int(let number) = value, (0...9).contains(number) else {
          throw ServerError.message("INVALID_ARGUMENT: priorities must be 0...9")
        }
        return number
      }
    }
    if let value = try string("dueStatus", from: filter) {
      guard let status = DueStatus(rawValue: value) else {
        throw ServerError.message("INVALID_ARGUMENT: invalid dueStatus")
      }
      search.dueStatus = status
    }
    let offset = try await cursors.offset(token: string("cursor"), search: search)
    let data = try await readInventory(includeFlags: true)
    let allowedLists = search.accountIds.map { ids in
      Set(data.lists.filter { ids.contains($0.source.id) }.map(\.id))
    }
    let fetched = data.reminders.filter {
      if fromDate != nil || beforeDate != nil {
        guard let date = (try? projectDate($0.dueDateComponents))?.instant,
          fromDate == nil || date >= fromDate!, beforeDate == nil || date < beforeDate!
        else { return false }
      }
      return (allowedLists == nil || allowedLists!.contains($0.listId ?? ""))
        && (search.listIds == nil || search.listIds!.contains($0.listId ?? ""))
        && (search.flagged == nil || $0.flagged == search.flagged)
        && (search.hasDueDate == nil || search.hasDueDate == ($0.dueDateComponents != nil))
        && matchesDays($0.dueDay, search.dueOnOrAfter, dayUpper)
        && (search.priorities == nil || search.priorities!.contains($0.priority))
        && (search.dueStatus == nil || $0.dueStatus == search.dueStatus)
        && (search.completed == nil || $0.completed == search.completed)
        && (search.query == nil || search.query!.isEmpty
          || (($0.name ?? "").lowercased().contains(search.query!.lowercased())
            || ($0.body ?? "").lowercased().contains(search.query!.lowercased())))
    }
    let items =
      try search.orderField.map {
        try orderReminders(fetched, field: $0, descending: search.descending)
      } ?? fetched
    let start = min(offset, items.count)
    let end = min(start + search.limit, items.count)
    var token: String?
    if end < items.count {
      token = await cursors.insert(search: search, offset: end)
    }
    return try result(
      SearchOutput(
        items: await mcpReminders(Array(items[start..<end])), totalCount: items.count,
        nextCursor: token))
  default: throw MCPError.invalidParams("Unknown tool")
  }
}
private let tools = toolsCatalog()
private let toolNames = Set(tools.map(\.name))

func handleMCP(method: String, headers: [String: String], body: Data) async throws
  -> ServiceResponse
{
  // Each HTTP request has isolated SDK protocol state, permitting independent clients.
  // The HTTP listener enforces Origin policy for all endpoints.
  let transport = StatelessHTTPServerTransport(
    validationPipeline: StandardValidationPipeline(validators: [
      AcceptHeaderValidator(mode: .jsonOnly),
      ContentTypeValidator(),
      ProtocolVersionValidator(),
    ]))
  let server = Server(
    name: "apple-reminders-server", version: "0.3.0",
    capabilities: .init(tools: .init(listChanged: false)))
  do {
    await server.withMethodHandler(ListTools.self) { params in
      guard params.cursor == nil else { throw MCPError.invalidParams("Tool catalog has no cursor") }
      return .init(tools: tools)
    }
    await server.withMethodHandler(CallTool.self) { params in
      guard toolNames.contains(params.name) else {
        throw MCPError.invalidParams("Unknown tool")
      }
      do { return try await callTool(params) } catch {
        return .init(
          content: [.text(text: String(describing: error), annotations: nil, _meta: nil)],
          isError: true)
      }
    }
    try await server.start(transport: transport)
    let response = await transport.handleRequest(
      .init(method: method, headers: headers, body: body, path: "/mcp"))
    await server.stop()
    return ServiceResponse(
      status: response.statusCode, type: response.headers["Content-Type"] ?? "application/json",
      body: response.bodyData ?? Data(), headers: response.headers)
  } catch {
    await server.stop()
    throw error
  }
}
