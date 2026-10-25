import Foundation
import MCP

private struct PageOutput<Item: Encodable>: Encodable {
  let items: [Item]
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
  let list: ListRecord?
  enum CodingKeys: CodingKey { case list }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(list, forKey: .list)
  }
}
private struct DefaultsOutput: Encodable {
  let list: ListRecord?
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
// Matching GraphQL types describe the same fields; makeSchema failing also stops serve.
private let fieldDescriptions = (try? graphQLFieldDescriptions()) ?? [:]
private func describe(_ value: Value?, _ text: String) -> Value? {
  guard case .object(var object)? = value, object["description"] == nil else { return value }
  object["description"] = .string(text)
  return .object(object)
}
// `type` names the GraphQL type whose field descriptions apply.
private func schema(_ properties: [String: Value], required: [String] = [], as type: String? = nil)
  -> Value
{
  var properties = properties
  for (key, text) in type.flatMap({ fieldDescriptions[$0] }) ?? [:] {
    properties[key] = describe(properties[key], text)
  }
  return .object([
    "type": "object", "properties": .object(properties),
    "required": .array(required.map(Value.string)), "additionalProperties": false,
  ])
}
private func primitive(_ type: String) -> Value { .object(["type": .string(type)]) }
private func array(_ item: Value) -> Value { .object(["type": "array", "items": item]) }
private func enumeration(_ values: [String]) -> Value {
  .object(["type": "string", "enum": .array(values.map(Value.string))])
}
private let reminderFilterKeys: Set<String> = [
  "accountIds", "listIds", "query", "completed", "priorities", "hasDueDate",
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
  for name in ["dueDate", "allDayDueDate", "startDate", "allDayStartDate", "timeZone", "dueDay"] {
    reminder[name] = nullable(primitive("string"))
  }
  reminder["flagged"] = .object([
    "type": "boolean",
    "description":
      "Set in reminders_create/reminders_update results when the write set flagged.",
  ])
  reminder["completed"] = primitive("boolean")
  reminder["priority"] = primitive("integer")
  reminder["startDateComponents"] = schema(parts)
  reminder["dueDateComponents"] = schema(parts)
  reminder["dueStatus"] = enumeration(DueStatus.allCases.map(\.rawValue))
  let structuredLocation = schema(
    [
      "title": primitive("string"), "latitude": primitive("number"),
      "longitude": primitive("number"), "radius": primitive("number"),
    ], required: ["radius"], as: "StructuredLocation")
  reminder["alarms"] = array(
    schema(
      [
        "absoluteDate": primitive("string"), "relativeOffset": primitive("number"),
        "proximity": enumeration(["none", "enter", "leave", "unknown"]),
        "structuredLocation": structuredLocation,
      ], required: ["relativeOffset", "proximity"], as: "RawAlarm"))
  reminder["rawAlarms"] = reminder["alarms"]
  let geofence = schema(
    [
      "title": primitive("string"), "latitude": primitive("number"),
      "longitude": primitive("number"), "radiusMeters": primitive("number"),
      "proximity": enumeration(["ARRIVE", "DEPART"]),
    ], required: ["latitude", "longitude", "radiusMeters", "proximity"], as: "Geofence")
  reminder["alarms"] = array(
    .object([
      "oneOf": .array([
        schema(
          ["kind": enumeration(["AbsoluteAlarm"]), "at": primitive("string")],
          required: ["kind", "at"], as: "AbsoluteAlarm"),
        schema(
          ["kind": enumeration(["RelativeAlarm"]), "offsetSeconds": primitive("number")],
          required: ["kind", "offsetSeconds"], as: "RelativeAlarm"),
        schema(
          ["kind": enumeration(["LocationAlarm"]), "geofence": geofence],
          required: ["kind", "geofence"], as: "LocationAlarm"),
      ])
    ]))
  var schedule: [String: Value] = [
    "frequency": enumeration(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]),
    "interval": primitive("integer"),
    "daysOfWeek": array(
      schema(
        [
          "day": enumeration(weekdayNames), "ordinal": primitive("integer"),
        ], required: ["day"], as: "ReminderRecurrenceDay")),
    "end": schema(
      ["until": primitive("string"), "count": primitive("integer")], as: "ReminderRecurrenceEnd"),
  ]
  for name in ["daysOfMonth", "monthsOfYear", "weeksOfYear", "daysOfYear", "setPositions"] {
    schedule[name] = array(primitive("integer"))
  }
  let rule = schema(schedule, required: ["frequency", "interval"], as: "ReminderRecurrence")
  reminder["recurrence"] = nullable(rule)
  var recurrence: [String: Value] = [
    "frequency": enumeration(["daily", "weekly", "monthly", "yearly", "unknown"]),
    "calendarIdentifier": primitive("string"), "interval": primitive("integer"),
    "firstDayOfTheWeek": primitive("integer"),
    "daysOfTheWeek": array(
      schema(
        ["dayOfTheWeek": primitive("integer"), "weekNumber": primitive("integer")],
        required: ["dayOfTheWeek", "weekNumber"], as: "RecurrenceDay")),
    "end": schema(
      ["endDate": primitive("string"), "occurrenceCount": primitive("integer")],
      required: ["occurrenceCount"], as: "RecurrenceEnd"),
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
      ], as: "RecurrenceRule"))
  // GraphQL describes projection failures as field errors; in MCP they fail the call.
  for (name, text) in [
    "dueDate": "The date and time by which the reminder is due.",
    "startDate": "The date and time at which work on the reminder starts.",
    "timeZone": "IANA time-zone identifier, or null for floating/local date interpretation.",
    "alarms":
      "Configured alerts; an empty list means no alerts. rawAlarms holds the stored values.",
    "recurrence":
      "A single repeating schedule; null when no recurrence is configured. recurrenceRules holds the stored rules.",
  ] { reminder[name] = describe(reminder[name], text) }
  let item = schema(
    reminder,
    required: [
      "rawAlarms", "recurrence", "dueDate", "allDayDueDate", "startDate", "allDayStartDate",
      "timeZone", "id", "completed", "priority", "dueDay", "dueStatus", "alarms",
      "recurrenceRules",
    ], as: "Reminder")
  let list = schema(
    [
      "allowsListModifications": primitive("boolean"), "subscribed": primitive("boolean"),
      "id": primitive("string"), "name": primitive("string"), "color": primitive("string"),
      "source": schema(
        ["id": primitive("string"), "title": primitive("string"), "type": primitive("integer")],
        required: ["id", "title", "type"]), "allowsContentModifications": primitive("boolean"),
      "isImmutable": primitive("boolean"), "isSubscribed": primitive("boolean"),
    ],
    required: [
      "id", "name", "source", "allowsContentModifications", "isImmutable", "isSubscribed",
    ],
    as: "ReminderList")
  let order = schema(
    [
      "field": enumeration(reminderSortFields), "direction": enumeration(["ASC", "DESC"]),
    ], required: ["field"], as: "ReminderOrder")
  let pagination: [String: Value] = [
    "limit": .object(["type": "integer", "minimum": 1, "maximum": 100, "default": 50]),
    "cursor": .object([
      "type": "string", "minLength": 1,
      "description":
        "Omit for the first page. Otherwise use nextCursor from the previous response with the same filter, orderBy, and limit. Each page reads live data, so concurrent changes can cause omissions or repeats.",
    ]),
  ]
  let search = schema(
    pagination.merging([
      "orderBy": order,
      "filter": schema(
        [
          "dueFrom": primitive("string"), "accountIds": array(primitive("string")),
          "listIds": array(primitive("string")), "hasDueDate": primitive("boolean"),
          "dueOnOrAfter": primitive("string"),
          "dueBefore": primitive("string"),
          "priorities": array(.object(["type": "integer", "minimum": 0, "maximum": 9])),
          "dueStatus": enumeration(DueStatus.allCases.map(\.rawValue)),
          "completed": primitive("boolean"), "query": primitive("string"),
        ], as: "ReminderFilter"),
    ]) { _, new in new })
  let listSearch = schema(
    pagination.merging([
      "filter": schema(
        [
          "query": primitive("string"), "accountIds": array(primitive("string")),
          "allowsContentModifications": primitive("boolean"), "subscribed": primitive("boolean"),
        ], as: "ListFilter"),
      "orderBy": schema(["direction": enumeration(["ASC", "DESC"])], as: "ListOrder"),
    ]) { _, new in new })
  let account = schema(
    ["id": primitive("string"), "name": primitive("string")], required: ["id", "name"],
    as: "Account")
  let counts = [
    "total", "completed", "incomplete", "overdue", "scheduled", "recurring", "withAlarms",
  ]
  var summary = Dictionary(uniqueKeysWithValues: counts.map { ($0, primitive("integer")) })
  summary["listId"] = primitive("string")
  let annotations = Tool.Annotations(
    readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  let alarmInput = schema(
    [
      "absoluteDate": primitive("string"), "relativeOffsetSeconds": primitive("number"),
      "geofence": schema(
        [
          "title": primitive("string"),
          "latitude": .object(["type": "number", "minimum": -90, "maximum": 90]),
          "longitude": .object(["type": "number", "minimum": -180, "maximum": 180]),
          "radiusMeters": .object(["type": "number", "minimum": 0]),
          "proximity": enumeration(["ARRIVE", "DEPART"]),
        ], required: ["latitude", "longitude", "radiusMeters", "proximity"], as: "GeofenceInput"),
    ], as: "ReminderAlarmInput")
  var writeFields = Dictionary(
    uniqueKeysWithValues: [
      "name", "body", "location", "url", "dueDate", "allDayDueDate", "startDate", "allDayStartDate",
    ].map { ($0, primitive("string")) })
  writeFields["priority"] = .object(["type": "integer", "minimum": 0, "maximum": 9])
  writeFields["alarms"] = array(alarmInput)
  writeFields["timeZone"] = primitive("string")
  writeFields["flagged"] = primitive("boolean")
  writeFields["remindMeDate"] = primitive("string")
  writeFields["recurrence"] = rule
  var createFields = writeFields
  createFields["listId"] = primitive("string")
  writeFields["completed"] = primitive("boolean")
  writeFields["completionDate"] = primitive("string")
  writeFields["clearFields"] = array(enumeration(ReminderClearValue.allCases.map(\.rawValue)))
  let created = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
  let changed = Tool.Annotations(
    readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
  let listPatch = schema(
    ["name": primitive("string"), "color": primitive("string"), "emblem": primitive("string")],
    as: "ListPatch")
  let listCreate = schema(
    [
      "name": primitive("string"), "accountId": primitive("string"), "color": primitive("string"),
      "emblem": primitive("string"),
    ], required: ["name", "accountId"], as: "CreateListInput")
  let navigation = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  return [
    Tool(
      name: "lists_create",
      description:
        "Create a list in an explicit account. Colors use opaque #RRGGBB or #RRGGBBFF. Emblems are Reminders icon names. If the emblem write fails after the save, the error has code WRITE_APPLIED and names the saved ID; do not retry creation blindly.",
      inputSchema: listCreate, annotations: created,
      outputSchema: schema(["list": list], required: ["list"])),
    Tool(
      name: "lists_update",
      description:
        "Update list name, color or emblem. Omitted values are unchanged; nulls and empty patches are invalid. If the emblem write fails after the save, the error has code WRITE_APPLIED and names the saved ID; refetch before retrying.",
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
      outputSchema: schema(
        ["deletedId": primitive("string")], required: ["deletedId"], as: "DeleteResult")),
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
        "Create an incomplete reminder. Specify listId or use the application's default list. Optional values must be omitted, not null. Timed/all-day due dates are exclusive; allDayStartDate is currently unsupported. Each alarm needs exactly one trigger; relative alarms require a start date. flagged and remindMeDate are applied after the reminder is saved; the result echoes flagged. A retry can create duplicates. A WRITE_APPLIED error means the save succeeded but a later step failed; refetch using the reported ID.",
      inputSchema: schema(createFields, required: ["name"], as: "CreateReminderInput"),
      annotations: created,
      outputSchema: schema(["reminder": item], required: ["reminder"])),
    Tool(
      name: "reminders_update",
      description:
        "Patch a reminder by ID. Omitted fields are unchanged; null is invalid. At least one change is required. clearFields removes optional values; [] alone is not a change. Do not set and clear a property together, or combine completed and completionDate changes. alarms replaces all alerts; [] removes them. Dates can affect alerts. flagged and remindMeDate are applied after the reminder is saved; the result echoes flagged. A WRITE_APPLIED error means the save succeeded but a later step failed; refetch before retrying.",
      inputSchema: schema(
        ["id": primitive("string"), "patch": schema(writeFields, as: "ReminderPatch")],
        required: ["id", "patch"]),
      annotations: changed, outputSchema: schema(["reminder": item], required: ["reminder"])),
    Tool(
      name: "reminders_delete",
      description:
        "Delete one reminder. Missing IDs return a NOT_FOUND tool error. Refetch before retrying after uncertain failures.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: changed,
      outputSchema: schema(
        ["deletedId": primitive("string")], required: ["deletedId"], as: "DeleteResult")),
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
        "Read a list by ID; absent identifiers return null. Emblems and containers are not included; read them through GraphQL.",
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
        [
          "items": array(schema(summary, required: counts + ["listId"], as: "ListSummary"))
        ], required: ["items"])),
    Tool(
      name: "lists_list",
      description:
        "Read lists filtered by name, account IDs, editability, and subscription. Use filter for search criteria. orderBy.direction selects name ordering; omission uses identifier order. Filters intersect. Pagination uses limit and cursor; keep the criteria unchanged across pages. Name ordering is case-insensitive with ID ascending ties.",
      inputSchema: listSearch, annotations: annotations,
      outputSchema: schema(
        [
          "items": array(list), "totalCount": primitive("integer"),
          "nextCursor": primitive("string"),
        ], required: ["items", "totalCount"], as: "ListPage")),
    Tool(
      name: "reminders_search",
      description:
        "Read reminders filtered by account/list IDs, completion, deadline presence, numeric priorities, due status and case-insensitive name-or-notes substring. Filters intersect; empty ID arrays match nothing. Supply criteria in filter. dueFrom and timestamp dueBefore bound deadline instants (inclusive/exclusive). All-day deadlines use midnight in their source zone. Calendar-day dueOnOrAfter and date-only dueBefore use reporting days; do not mix bound modes. orderBy supports NAME, DUE_DATE, PRIORITY, CREATION_DATE, MODIFICATION_DATE, COMPLETION_DATE with ASC/DESC, nulls last, and ID ascending ties. Omitted orderBy uses identifier order; priorities use numeric order. Cursor is the next page offset; keep criteria and limit unchanged across pages. Optional unavailable values are omitted. Dates retain their stored components; omitted hours mean date-only and omitted zones mean floating. A reminder whose dates, alarms, or recurrence cannot be projected fails the call. Flags, alert dates, containers, and emblems are not included; read them through GraphQL.",
      inputSchema: search, annotations: annotations,
      outputSchema: schema(
        [
          "items": array(item), "totalCount": primitive("integer"),
          "nextCursor": primitive("string"),
        ], required: ["items", "totalCount"], as: "ReminderPage")),
    Tool(
      name: "reminders_get",
      description:
        "Read one reminder with component and projected dates, alarms and recurrence; returns null when absent. Dates, alarms, or recurrence that cannot be projected fail the call. Flags, alert dates, containers, and emblems are not included; read them through GraphQL.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: annotations,
      outputSchema: schema(["reminder": nullable(item)], required: ["reminder"])),
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
      throw ServerError.invalidArgument("filter must be an object with known fields")
    }
    return filter
  }
  func keys(_ allowed: Set<String>) throws {
    guard Set(args.keys).isSubset(of: allowed) else {
      throw ServerError.invalidArgument("Unknown argument")
    }
  }
  func string(_ key: String, from values: [String: Value]? = nil) throws -> String? {
    guard let value = (values ?? args)[key] else { return nil }
    guard let text = value.stringValue else {
      throw ServerError.invalidArgument("\(key) must be a string")
    }
    return text
  }
  // A cursor is the next page's offset; the client keeps the criteria unchanged.
  func cursor() throws -> Int {
    guard let value = args["cursor"] else { return 0 }
    guard let token = value.stringValue, let offset = Int(token), offset >= 0 else {
      throw ServerError.invalidArgument(
        "cursor must be a nextCursor string from the previous response. Omit cursor for the first page."
      )
    }
    return offset
  }
  func bool(_ key: String, from values: [String: Value]? = nil) throws -> Bool? {
    guard let value = (values ?? args)[key] else { return nil }
    guard case .bool(let result) = value else {
      throw ServerError.invalidArgument("\(key) must be boolean")
    }
    return result
  }
  func ids(_ key: String, from values: [String: Value]? = nil) throws -> [String]? {
    guard let value = (values ?? args)[key] else { return nil }
    guard case .array(let values) = value else {
      throw ServerError.invalidArgument("\(key) must be an array")
    }
    return try values.map { value in
      guard case .string(let id) = value, !id.isEmpty else {
        throw ServerError.invalidArgument("\(key) must contain nonempty identifiers")
      }
      return id
    }
  }
  func limit() throws -> Int {
    guard let value = args["limit"] else { return 50 }
    guard case .int(let number) = value, (1...100).contains(number) else {
      throw ServerError.invalidArgument("limit must be 1...100")
    }
    return number
  }
  // The page at the cursor offset; nextCursor is the following page's offset.
  func page<Item: Encodable>(_ items: [Item]) throws -> PageOutput<Item> {
    let start = try min(cursor(), items.count)
    let end = try min(start + limit(), items.count)
    return PageOutput(
      items: Array(items[start..<end]), totalCount: items.count,
      nextCursor: end < items.count ? String(end) : nil)
  }
  func descending(_ order: MutationInput) throws -> Bool {
    let direction = try order["direction"].isSet ? order["direction"].stringValue() : "ASC"
    guard ["ASC", "DESC"].contains(direction) else {
      throw ServerError.invalidArgument("invalid order direction")
    }
    return direction == "DESC"
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
        throw ServerError.invalidArgument("id and patch required")
      }
      input = try mutationInput(patch)
      try input.rejectNulls()
      request = .update(id: id, changes: try reminderChanges(input, creating: false))
    }
    let saved = try await mutateReminder(request).savedRecord()
    do { return try result(GetOutput(reminder: MCPReminder(record: saved))) } catch {
      throw ServerError.writeApplied(
        "reminder \(saved.id) was saved, but response projection failed: \(error). Refetch before retrying."
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
        throw ServerError.invalidArgument("id and patch required")
      }
      let input = try mutationInput(value)
      try input.rejectNulls()
      request = .update(id: id, changes: try listChanges(input, creating: false))
    }
    let saved = try await mutateList(request).savedRecord()
    do { return try result(ListOutput(list: saved)) } catch {
      throw ServerError.writeApplied(
        "list \(saved.id) was saved, but response projection failed: \(error). Refetch before retrying"
      )
    }
  case "lists_delete":
    try keys(["id", "allowNonEmpty"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.invalidArgument("id required")
    }
    let deleted = try await mutateList(
      .delete(id: id, allowNonEmpty: try bool("allowNonEmpty") ?? false)
    ).deletion()
    return try result(deleted)
  case "reminders_show":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.invalidArgument("id required")
    }
    guard case .reminder(let shown) = try await showRemindersObject(id, isList: false) else {
      throw ServerError.internalError("Expected a reminder")
    }
    do { return try result(GetOutput(reminder: MCPReminder(record: shown))) } catch {
      throw ServerError.showApplied(
        "reminder \(id) was shown, but response projection failed: \(error)")
    }
  case "lists_show":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.invalidArgument("id required")
    }
    guard case .list(let shown) = try await showRemindersObject(id, isList: true) else {
      throw ServerError.internalError("Expected a list")
    }
    do { return try result(ListOutput(list: shown)) } catch {
      throw ServerError.showApplied(
        "list \(id) was shown, but response projection failed: \(error)")
    }
  case "reminders_delete":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.invalidArgument("id required")
    }
    let deleted = try await mutateReminder(.delete(id: id)).deletion()
    return try result(deleted)
  case "accounts_get":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.invalidArgument("id required")
    }
    return try result(AccountOutput(account: await readLists().accounts.first { $0.id == id }))
  case "lists_list":
    try keys(["filter", "orderBy", "limit", "cursor"])
    let filter = try filters(listFilterKeys)
    var search = Search()
    search.query = try string("query", from: filter)
    search.accountIds = try ids("accountIds", from: filter)
    search.allowsContentModifications = try bool("allowsContentModifications", from: filter)
    search.subscribed = try bool("subscribed", from: filter)
    if let rawOrder = args["orderBy"] {
      let order = try mutationInput(rawOrder)
      try order.rejectNulls()
      try order.checkKeys(["direction"])
      search.orderField = "NAME"
      search.descending = try descending(order)
    }
    return try await result(page(search.lists(readLists())))
  case "accounts_list":
    try keys([])
    return try result(AccountsOutput(items: await readLists().accounts))
  case "lists_get":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.invalidArgument("id required")
    }
    return try result(ListOutput(list: await readList(id: id)))
  case "defaults_get":
    try keys([])
    let data = try await readLists()
    return try result(
      DefaultsOutput(
        list: data.defaultList,
        account: data.defaultAccount))
  case "lists_summary":
    try keys(["listId"])
    let id = try string("listId")
    guard id != "" else { throw ServerError.invalidArgument("listId must not be empty") }
    let data = try await readRemindersData()
    return try result(
      SummaryOutput(
        items: data.lists.filter { id == nil || $0.id == id }.map {
          summarize(data, listId: $0.id)
        }))
  case "reminders_get":
    try keys(["id"])
    guard let id = try string("id"), !id.isEmpty else {
      throw ServerError.invalidArgument("id required")
    }
    return try result(GetOutput(reminder: await readReminder(id: id).map(MCPReminder.init)))
  case "reminders_search":
    try keys(["filter", "orderBy", "limit", "cursor"])
    let filter = try filters(reminderFilterKeys)
    var search = Search(
      query: try string("query", from: filter),
      dueOnOrAfter: try string("dueOnOrAfter", from: filter),
      dueBefore: try string("dueBefore", from: filter))
    search.accountIds = try ids("accountIds", from: filter)
    search.listIds = try ids("listIds", from: filter)
    search.hasDueDate = try bool("hasDueDate", from: filter)
    search.dueFrom = try string("dueFrom", from: filter)
    if let value = args["orderBy"] {
      let order = try mutationInput(value)
      try order.rejectNulls()
      try order.checkKeys(["field", "direction"])
      let field = try order["field"].stringValue()
      guard reminderSortFields.contains(field) else {
        throw ServerError.invalidArgument("invalid order field")
      }
      search.orderField = field
      search.descending = try descending(order)
    }
    search.completed = try bool("completed", from: filter)
    if let value = filter["priorities"] {
      guard case .array(let values) = value else {
        throw ServerError.invalidArgument("priorities must be an integer array")
      }
      search.priorities = try values.map { value in
        guard case .int(let number) = value, (0...9).contains(number) else {
          throw ServerError.invalidArgument("priorities must be 0...9")
        }
        return number
      }
    }
    if let value = try string("dueStatus", from: filter) {
      guard let status = DueStatus(rawValue: value) else {
        throw ServerError.invalidArgument("invalid dueStatus")
      }
      search.dueStatus = status
    }
    return try await result(page(search.reminders(readRemindersData()).map(MCPReminder.init)))
  default: throw MCPError.invalidParams("Unknown tool")
  }
}
private let tools = toolsCatalog()
private let toolNames = Set(tools.map(\.name))
// A tool without readOnlyHint requires write access.
private let readOnlyTools = Set(tools.filter { $0.annotations.readOnlyHint == true }.map(\.name))

func mcpToolsJSON() throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(ListTools.Result(tools: tools)), as: UTF8.self)
}

// Tool errors are JSON like successful results, with the code clients act on.
private func errorText(_ error: Error) -> String {
  let server = error as? ServerError
  let payload: [String: String] = [
    "code": server?.code.rawValue ?? ErrorCode.internalError.rawValue,
    "message": server?.message ?? String(describing: error),
  ]
  let data = try? JSONEncoder().encode(["error": payload])
  return data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: error)
}

// Records the tool outcome so the logger need not reparse large result bodies.
private final class ToolOutcome: @unchecked Sendable {
  var ran = false
  var failed = false
}
func handleMCP(method: String, headers: [String: String], body: Data, access: Capabilities.Access)
  async throws
  -> ServiceResponse
{
  let outcome = ToolOutcome()
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
      outcome.ran = true
      return .init(tools: tools)
    }
    await server.withMethodHandler(CallTool.self) { params in
      guard toolNames.contains(params.name) else {
        throw MCPError.invalidParams("Unknown tool")
      }
      outcome.ran = true
      guard access == .write || (access == .read && readOnlyTools.contains(params.name)) else {
        outcome.failed = true
        return .init(
          content: [
            .text(text: "Forbidden: MCP write access required", annotations: nil, _meta: nil)
          ], isError: true)
      }
      do { return try await callTool(params) } catch {
        outcome.failed = true
        return .init(
          content: [.text(text: errorText(error), annotations: nil, _meta: nil)], isError: true)
      }
    }
    try await server.start(transport: transport)
    let response = await transport.handleRequest(
      .init(method: method, headers: headers, body: body, path: "/mcp"))
    await server.stop()
    return ServiceResponse(
      status: response.statusCode, type: response.headers["Content-Type"] ?? "application/json",
      body: response.bodyData ?? Data(), headers: response.headers,
      failure: outcome.failed ? "mcp_tool" : nil, classified: outcome.ran)
  } catch {
    await server.stop()
    throw error
  }
}
