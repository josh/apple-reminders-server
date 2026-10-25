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
// Adds a description unless the property already has one.
private func describe(_ value: Value, _ text: String) -> Value {
  guard case .object(var object) = value, object["description"] == nil else { return value }
  object["description"] = .string(text)
  return .object(object)
}
// Describes properties built up step by step, by name.
private func describing(_ properties: [String: Value], _ descriptions: [(String, String)])
  -> [String: Value]
{
  var properties = properties
  for (key, text) in descriptions { properties[key] = properties[key].map { describe($0, text) } }
  return properties
}
private func schema(_ properties: [String: Value], required: [String] = []) -> Value {
  .object([
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
      "title": describe(primitive("string"), FieldDocs.StructuredLocation.title),
      "latitude": describe(primitive("number"), FieldDocs.StructuredLocation.latitude),
      "longitude": describe(primitive("number"), FieldDocs.StructuredLocation.longitude),
      "radius": describe(primitive("number"), FieldDocs.StructuredLocation.radius),
    ], required: ["radius"])
  reminder["alarms"] = array(
    schema(
      [
        "absoluteDate": describe(primitive("string"), FieldDocs.RawAlarm.absoluteDate),
        "relativeOffset": describe(primitive("number"), FieldDocs.RawAlarm.relativeOffset),
        "proximity": describe(
          enumeration(["none", "enter", "leave", "unknown"]), FieldDocs.RawAlarm.proximity),
        "structuredLocation": describe(structuredLocation, FieldDocs.RawAlarm.structuredLocation),
      ], required: ["relativeOffset", "proximity"]))
  reminder["rawAlarms"] = reminder["alarms"]
  let geofence = schema(
    [
      "title": describe(primitive("string"), FieldDocs.Geofence.title),
      "latitude": describe(primitive("number"), FieldDocs.Geofence.latitude),
      "longitude": describe(primitive("number"), FieldDocs.Geofence.longitude),
      "radiusMeters": describe(primitive("number"), FieldDocs.Geofence.radiusMeters),
      "proximity": describe(enumeration(["ARRIVE", "DEPART"]), FieldDocs.Geofence.proximity),
    ], required: ["latitude", "longitude", "radiusMeters", "proximity"])
  reminder["alarms"] = array(
    .object([
      "oneOf": .array([
        schema(
          [
            "kind": enumeration(["AbsoluteAlarm"]),
            "at": describe(primitive("string"), FieldDocs.AbsoluteAlarm.at),
          ],
          required: ["kind", "at"]),
        schema(
          [
            "kind": enumeration(["RelativeAlarm"]),
            "offsetSeconds": describe(primitive("number"), FieldDocs.RelativeAlarm.offsetSeconds),
          ],
          required: ["kind", "offsetSeconds"]),
        schema(
          [
            "kind": enumeration(["LocationAlarm"]),
            "geofence": describe(geofence, FieldDocs.LocationAlarm.geofence),
          ],
          required: ["kind", "geofence"]),
      ])
    ]))
  var schedule: [String: Value] = [
    "frequency": enumeration(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]),
    "interval": primitive("integer"),
    "daysOfWeek": array(
      schema(
        [
          "day": describe(enumeration(weekdayNames), FieldDocs.ScheduleDay.day),
          "ordinal": describe(primitive("integer"), FieldDocs.ScheduleDay.ordinal),
        ], required: ["day"])),
    "end": schema(
      [
        "until": describe(primitive("string"), FieldDocs.ScheduleEnd.until),
        "count": describe(primitive("integer"), FieldDocs.ScheduleEnd.count),
      ]),
  ]
  for (name, description) in FieldDocs.Schedule.selectors {
    schedule[name] = describe(array(primitive("integer")), description)
  }
  schedule = describing(
    schedule,
    [
      ("frequency", FieldDocs.Schedule.frequency), ("interval", FieldDocs.Schedule.interval),
      ("daysOfWeek", FieldDocs.Schedule.daysOfWeek), ("end", FieldDocs.Schedule.end),
    ])
  let rule = schema(schedule, required: ["frequency", "interval"])
  reminder["recurrence"] = nullable(rule)
  var recurrence: [String: Value] = [
    "frequency": enumeration(["daily", "weekly", "monthly", "yearly", "unknown"]),
    "calendarIdentifier": primitive("string"), "interval": primitive("integer"),
    "firstDayOfTheWeek": primitive("integer"),
    "daysOfTheWeek": array(
      schema(
        [
          "dayOfTheWeek": describe(primitive("integer"), FieldDocs.RecurrenceDay.dayOfTheWeek),
          "weekNumber": describe(primitive("integer"), FieldDocs.RecurrenceDay.weekNumber),
        ],
        required: ["dayOfTheWeek", "weekNumber"])),
    "end": schema(
      [
        "endDate": describe(primitive("string"), FieldDocs.RecurrenceEnd.endDate),
        "occurrenceCount": describe(primitive("integer"), FieldDocs.RecurrenceEnd.occurrenceCount),
      ],
      required: ["occurrenceCount"]),
  ]
  for name in [
    "daysOfTheMonth", "daysOfTheYear", "weeksOfTheYear", "monthsOfTheYear", "setPositions",
  ] { recurrence[name] = array(primitive("integer")) }
  recurrence = describing(
    recurrence,
    [
      ("frequency", FieldDocs.RecurrenceRule.frequency),
      ("calendarIdentifier", FieldDocs.RecurrenceRule.calendarIdentifier),
      ("interval", FieldDocs.RecurrenceRule.interval),
      ("firstDayOfTheWeek", FieldDocs.RecurrenceRule.firstDayOfTheWeek),
      ("daysOfTheWeek", FieldDocs.RecurrenceRule.daysOfTheWeek),
      ("end", FieldDocs.RecurrenceRule.end),
      ("daysOfTheMonth", FieldDocs.RecurrenceRule.daysOfTheMonth),
      ("daysOfTheYear", FieldDocs.RecurrenceRule.daysOfTheYear),
      ("weeksOfTheYear", FieldDocs.RecurrenceRule.weeksOfTheYear),
      ("monthsOfTheYear", FieldDocs.RecurrenceRule.monthsOfTheYear),
      ("setPositions", FieldDocs.RecurrenceRule.setPositions),
    ])
  reminder["recurrenceRules"] = array(
    schema(
      recurrence,
      required: [
        "frequency", "calendarIdentifier", "interval", "firstDayOfTheWeek", "daysOfTheWeek",
        "daysOfTheMonth", "daysOfTheYear", "weeksOfTheYear", "monthsOfTheYear", "setPositions",
      ]))
  // GraphQL describes projection failures as field errors; in MCP they fail the call.
  for (name, text) in [
    "dueDate": "The date and time by which the reminder is due.",
    "startDate": "The date and time at which work on the reminder starts.",
    "timeZone": "IANA time-zone identifier, or null for floating/local date interpretation.",
    "alarms":
      "Configured alerts; an empty list means no alerts. rawAlarms holds the stored values.",
    "recurrence":
      "A single repeating schedule; null when no recurrence is configured. recurrenceRules holds the stored rules.",
  ] { reminder[name] = reminder[name].map { describe($0, text) } }
  reminder = describing(
    reminder,
    [
      ("id", FieldDocs.Reminder.id), ("name", FieldDocs.Reminder.name),
      ("body", FieldDocs.Reminder.body), ("completed", FieldDocs.Reminder.completed),
      ("priority", FieldDocs.Reminder.priority), ("creationDate", FieldDocs.Reminder.creationDate),
      ("completionDate", FieldDocs.Reminder.completionDate),
      ("modificationDate", FieldDocs.Reminder.modificationDate),
      ("location", FieldDocs.Reminder.location), ("dueDay", FieldDocs.Reminder.dueDay),
      ("listId", FieldDocs.Reminder.listId), ("url", FieldDocs.Reminder.url),
      ("startDateComponents", FieldDocs.Reminder.startDateComponents),
      ("dueDateComponents", FieldDocs.Reminder.dueDateComponents),
      ("dueStatus", FieldDocs.Reminder.dueStatus), ("rawAlarms", FieldDocs.Reminder.rawAlarms),
      ("recurrenceRules", FieldDocs.Reminder.recurrenceRules),
      ("allDayDueDate", FieldDocs.Reminder.allDayDueDate),
      ("allDayStartDate", FieldDocs.Reminder.allDayStartDate),
    ])
  let item = schema(
    reminder,
    required: [
      "rawAlarms", "recurrence", "dueDate", "allDayDueDate", "startDate", "allDayStartDate",
      "timeZone", "id", "completed", "priority", "dueDay", "dueStatus", "alarms",
      "recurrenceRules",
    ])
  let list = schema(
    [
      "allowsListModifications": describe(
        primitive("boolean"), FieldDocs.ReminderList.allowsListModifications),
      "subscribed": describe(primitive("boolean"), FieldDocs.ReminderList.subscribed),
      "id": describe(primitive("string"), FieldDocs.ReminderList.id),
      "name": describe(primitive("string"), FieldDocs.ReminderList.name),
      "color": describe(primitive("string"), FieldDocs.ReminderList.color),
      "source": schema(
        ["id": primitive("string"), "title": primitive("string"), "type": primitive("integer")],
        required: ["id", "title", "type"]),
      "allowsContentModifications": describe(
        primitive("boolean"), FieldDocs.ReminderList.allowsContentModifications),
      "isImmutable": primitive("boolean"), "isSubscribed": primitive("boolean"),
    ],
    required: [
      "id", "name", "source", "allowsContentModifications", "isImmutable", "isSubscribed",
    ])
  let order = schema(
    [
      "field": describe(enumeration(reminderSortFields), FieldDocs.ReminderOrder.field),
      "direction": describe(enumeration(["ASC", "DESC"]), FieldDocs.ReminderOrder.direction),
    ], required: ["field"])
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
          "dueFrom": describe(primitive("string"), FieldDocs.ReminderFilter.dueFrom),
          "accountIds": describe(array(primitive("string")), FieldDocs.ReminderFilter.accountIds),
          "listIds": describe(array(primitive("string")), FieldDocs.ReminderFilter.listIds),
          "hasDueDate": describe(primitive("boolean"), FieldDocs.ReminderFilter.hasDueDate),
          "dueOnOrAfter": describe(primitive("string"), FieldDocs.ReminderFilter.dueOnOrAfter),
          "dueBefore": describe(primitive("string"), FieldDocs.ReminderFilter.dueBefore),
          "priorities": describe(
            array(.object(["type": "integer", "minimum": 0, "maximum": 9])),
            FieldDocs.ReminderFilter.priorities),
          "dueStatus": describe(
            enumeration(DueStatus.allCases.map(\.rawValue)), FieldDocs.ReminderFilter.dueStatus),
          "completed": describe(primitive("boolean"), FieldDocs.ReminderFilter.completed),
          "query": describe(primitive("string"), FieldDocs.ReminderFilter.query),
        ]),
    ]) { _, new in new })
  let listSearch = schema(
    pagination.merging([
      "filter": schema(
        [
          "query": describe(primitive("string"), FieldDocs.ListFilter.query),
          "accountIds": describe(array(primitive("string")), FieldDocs.ListFilter.accountIds),
          "allowsContentModifications": describe(
            primitive("boolean"), FieldDocs.ListFilter.allowsContentModifications),
          "subscribed": describe(primitive("boolean"), FieldDocs.ListFilter.subscribed),
        ]),
      "orderBy": schema([
        "direction": describe(enumeration(["ASC", "DESC"]), FieldDocs.ListOrder.direction)
      ]),
    ]) { _, new in new })
  let account = schema(
    [
      "id": describe(primitive("string"), FieldDocs.Account.id),
      "name": describe(primitive("string"), FieldDocs.Account.name),
    ], required: ["id", "name"])
  let counts = [
    "total", "completed", "incomplete", "overdue", "scheduled", "recurring", "withAlarms",
  ]
  var summary = Dictionary(uniqueKeysWithValues: counts.map { ($0, primitive("integer")) })
  summary["listId"] = primitive("string")
  summary = describing(
    summary,
    [
      ("total", FieldDocs.ListSummary.total), ("completed", FieldDocs.ListSummary.completed),
      ("incomplete", FieldDocs.ListSummary.incomplete), ("overdue", FieldDocs.ListSummary.overdue),
      ("scheduled", FieldDocs.ListSummary.scheduled),
      ("recurring", FieldDocs.ListSummary.recurring),
      ("withAlarms", FieldDocs.ListSummary.withAlarms),
    ])
  let annotations = Tool.Annotations(
    readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  let alarmInput = schema([
    "absoluteDate": describe(primitive("string"), FieldDocs.ReminderAlarmInput.absoluteDate),
    "relativeOffsetSeconds": describe(
      primitive("number"), FieldDocs.ReminderAlarmInput.relativeOffsetSeconds),
    "geofence": describe(
      schema(
        [
          "title": describe(primitive("string"), FieldDocs.Geofence.title),
          "latitude": describe(
            .object(["type": "number", "minimum": -90, "maximum": 90]), FieldDocs.Geofence.latitude),
          "longitude": describe(
            .object(["type": "number", "minimum": -180, "maximum": 180]),
            FieldDocs.Geofence.longitude),
          "radiusMeters": describe(
            .object(["type": "number", "minimum": 0]), FieldDocs.Geofence.radiusMeters),
          "proximity": describe(enumeration(["ARRIVE", "DEPART"]), FieldDocs.Geofence.proximity),
        ], required: ["latitude", "longitude", "radiusMeters", "proximity"]),
      FieldDocs.ReminderAlarmInput.geofence),
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
  writeFields["recurrence"] = rule
  var createFields = writeFields
  createFields["listId"] = primitive("string")
  createFields = describing(
    createFields,
    [
      ("name", FieldDocs.CreateReminderInput.name), ("body", FieldDocs.CreateReminderInput.body),
      ("priority", FieldDocs.CreateReminderInput.priority),
      ("location", FieldDocs.CreateReminderInput.location),
      ("url", FieldDocs.CreateReminderInput.url),
      ("dueDate", FieldDocs.CreateReminderInput.dueDate),
      ("allDayDueDate", FieldDocs.CreateReminderInput.allDayDueDate),
      ("startDate", FieldDocs.CreateReminderInput.startDate),
      ("allDayStartDate", FieldDocs.CreateReminderInput.allDayStartDate),
      ("timeZone", FieldDocs.CreateReminderInput.timeZone),
      ("flagged", FieldDocs.CreateReminderInput.flagged),
      ("remindMeDate", FieldDocs.CreateReminderInput.remindMeDate),
      ("alarms", FieldDocs.CreateReminderInput.alarms),
      ("recurrence", FieldDocs.CreateReminderInput.recurrence),
      ("listId", FieldDocs.CreateReminderInput.listId),
    ])
  writeFields["completed"] = primitive("boolean")
  writeFields["completionDate"] = primitive("string")
  writeFields["clearFields"] = array(enumeration(ReminderClearValue.allCases.map(\.rawValue)))
  writeFields = describing(
    writeFields,
    [
      ("name", FieldDocs.ReminderPatch.name), ("body", FieldDocs.ReminderPatch.body),
      ("priority", FieldDocs.ReminderPatch.priority),
      ("location", FieldDocs.ReminderPatch.location), ("url", FieldDocs.ReminderPatch.url),
      ("dueDate", FieldDocs.ReminderPatch.dueDate),
      ("allDayDueDate", FieldDocs.ReminderPatch.allDayDueDate),
      ("startDate", FieldDocs.ReminderPatch.startDate),
      ("allDayStartDate", FieldDocs.ReminderPatch.allDayStartDate),
      ("timeZone", FieldDocs.ReminderPatch.timeZone), ("flagged", FieldDocs.ReminderPatch.flagged),
      ("remindMeDate", FieldDocs.ReminderPatch.remindMeDate),
      ("alarms", FieldDocs.ReminderPatch.alarms),
      ("recurrence", FieldDocs.ReminderPatch.recurrence),
      ("completionDate", FieldDocs.ReminderPatch.completionDate),
      ("completed", FieldDocs.ReminderPatch.completed),
      ("clearFields", FieldDocs.ReminderPatch.clearFields),
    ])
  let created = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
  let changed = Tool.Annotations(
    readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
  let listPatch = schema(
    [
      "name": describe(primitive("string"), FieldDocs.ListPatch.name),
      "color": describe(primitive("string"), FieldDocs.ListPatch.color),
      "emblem": describe(primitive("string"), FieldDocs.ListPatch.emblem),
    ])
  let listCreate = schema(
    [
      "name": describe(primitive("string"), FieldDocs.CreateListInput.name),
      "accountId": describe(primitive("string"), FieldDocs.CreateListInput.accountId),
      "color": describe(primitive("string"), FieldDocs.CreateListInput.color),
      "emblem": describe(primitive("string"), FieldDocs.CreateListInput.emblem),
    ], required: ["name", "accountId"])
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
        ["deletedId": describe(primitive("string"), FieldDocs.DeleteResult.deletedId)],
        required: ["deletedId"])),
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
      inputSchema: schema(createFields, required: ["name"]),
      annotations: created,
      outputSchema: schema(["reminder": item], required: ["reminder"])),
    Tool(
      name: "reminders_update",
      description:
        "Patch a reminder by ID. Omitted fields are unchanged; null is invalid. At least one change is required. clearFields removes optional values; [] alone is not a change. Do not set and clear a property together, or combine completed and completionDate changes. alarms replaces all alerts; [] removes them. Dates can affect alerts. flagged and remindMeDate are applied after the reminder is saved; the result echoes flagged. A WRITE_APPLIED error means the save succeeded but a later step failed; refetch before retrying.",
      inputSchema: schema(
        ["id": primitive("string"), "patch": schema(writeFields)],
        required: ["id", "patch"]),
      annotations: changed, outputSchema: schema(["reminder": item], required: ["reminder"])),
    Tool(
      name: "reminders_delete",
      description:
        "Delete one reminder. Missing IDs return a NOT_FOUND tool error. Refetch before retrying after uncertain failures.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: changed,
      outputSchema: schema(
        ["deletedId": describe(primitive("string"), FieldDocs.DeleteResult.deletedId)],
        required: ["deletedId"])),
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
          "items": array(schema(summary, required: counts + ["listId"]))
        ], required: ["items"])),
    Tool(
      name: "lists_list",
      description:
        "Read lists filtered by name, account IDs, editability, and subscription. Use filter for search criteria. orderBy.direction selects name ordering; omission uses identifier order. Filters intersect. Pagination uses limit and cursor; keep the criteria unchanged across pages. Name ordering is case-insensitive with ID ascending ties.",
      inputSchema: listSearch, annotations: annotations,
      outputSchema: schema(
        [
          "items": describe(array(list), FieldDocs.ListPage.items),
          "totalCount": describe(primitive("integer"), FieldDocs.ListPage.totalCount),
          "nextCursor": primitive("string"),
        ], required: ["items", "totalCount"])),
    Tool(
      name: "reminders_search",
      description:
        "Read reminders filtered by account/list IDs, completion, deadline presence, numeric priorities, due status and case-insensitive name-or-notes substring. Filters intersect; empty ID arrays match nothing. Supply criteria in filter. dueFrom and timestamp dueBefore bound deadline instants (inclusive/exclusive). All-day deadlines use midnight in their source zone. Calendar-day dueOnOrAfter and date-only dueBefore use reporting days; do not mix bound modes. orderBy supports NAME, DUE_DATE, PRIORITY, CREATION_DATE, MODIFICATION_DATE, COMPLETION_DATE with ASC/DESC, nulls last, and ID ascending ties. Omitted orderBy uses identifier order; priorities use numeric order. Cursor is the next page offset; keep criteria and limit unchanged across pages. Optional unavailable values are omitted. Dates retain their stored components; omitted hours mean date-only and omitted zones mean floating. A reminder whose dates, alarms, or recurrence cannot be projected fails the call. Flags, alert dates, containers, and emblems are not included; read them through GraphQL.",
      inputSchema: search, annotations: annotations,
      outputSchema: schema(
        [
          "items": describe(array(item), FieldDocs.ReminderPage.items),
          "totalCount": describe(primitive("integer"), FieldDocs.ReminderPage.totalCount),
          "nextCursor": primitive("string"),
        ], required: ["items", "totalCount"])),
    Tool(
      name: "reminders_get",
      description:
        "Read one reminder with component and projected dates, alarms and recurrence; returns null when absent. Dates, alarms, or recurrence that cannot be projected fail the call. Flags, alert dates, containers, and emblems are not included; read them through GraphQL.",
      inputSchema: schema(["id": primitive("string")], required: ["id"]), annotations: annotations,
      outputSchema: schema(["reminder": nullable(item)], required: ["reminder"])),
  ]
}
// MCP inputs omit optional values; an explicit null anywhere is invalid.
private func rejectNulls(_ value: Value) throws {
  switch value {
  case .null: throw ServerError.invalidArgument("Omit optional MCP inputs instead of sending null")
  case .object(let object): for value in object.values { try rejectNulls(value) }
  case .array(let array): for value in array { try rejectNulls(value) }
  default: break
  }
}
private struct ListOrderInput: Decodable {
  let direction: InputField<String>
  enum CodingKeys: String, CodingKey, CaseIterable { case direction }
  init(from decoder: Decoder) throws {
    direction = try decoder.inputContainer(keyedBy: CodingKeys.self).field(.direction)
  }
}
private struct ReminderOrderInput: Decodable {
  let field: String
  let direction: InputField<String>
  enum CodingKeys: String, CodingKey, CaseIterable { case field, direction }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    field = try c.decode(String.self, forKey: .field)
    direction = try c.field(.direction)
  }
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
  func descending(_ direction: InputField<String>) throws -> Bool {
    let direction = direction.value ?? "ASC"
    guard ["ASC", "DESC"].contains(direction) else {
      throw ServerError.invalidArgument("invalid order direction")
    }
    return direction == "DESC"
  }
  switch params.name {
  case "reminders_create", "reminders_update":
    let request: ReminderWrite
    if params.name == "reminders_create" {
      try rejectNulls(.object(args))
      let input = try decodeInput(ReminderInput.self, from: args)
      request = .create(
        listID: input.listId.value, changes: try reminderChanges(input, creating: true))
    } else {
      try keys(["id", "patch"])
      guard let id = try string("id"), !id.isEmpty, let patch = args["patch"] else {
        throw ServerError.invalidArgument("id and patch required")
      }
      try rejectNulls(patch)
      request = .update(
        id: id,
        changes: try reminderChanges(decodeInput(ReminderInput.self, from: patch), creating: false))
    }
    let saved = try await writeReminder(request).savedRecord()
    do { return try result(GetOutput(reminder: MCPReminder(record: saved))) } catch {
      throw ServerError.writeApplied(
        "reminder \(saved.id) was saved, but response projection failed: \(error). Refetch before retrying."
      )
    }
  case "lists_create", "lists_update":
    let request: ListWrite
    if params.name == "lists_create" {
      try rejectNulls(.object(args))
      let input = try decodeInput(ListInput.self, from: args)
      request = .create(
        accountID: try input.accountId.required("accountId"),
        changes: try listChanges(input, creating: true))
    } else {
      try keys(["id", "patch"])
      guard let id = try string("id"), !id.isEmpty, let value = args["patch"] else {
        throw ServerError.invalidArgument("id and patch required")
      }
      try rejectNulls(value)
      request = .update(
        id: id, changes: try listChanges(decodeInput(ListInput.self, from: value), creating: false))
    }
    let saved = try await writeList(request).savedRecord()
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
    let deleted = try await writeList(
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
    let deleted = try await writeReminder(.delete(id: id)).deletion()
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
      try rejectNulls(rawOrder)
      let order = try decodeInput(ListOrderInput.self, from: rawOrder)
      search.orderField = "NAME"
      search.descending = try descending(order.direction)
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
      try rejectNulls(value)
      let order = try decodeInput(ReminderOrderInput.self, from: value)
      guard reminderSortFields.contains(order.field) else {
        throw ServerError.invalidArgument("invalid order field")
      }
      search.orderField = order.field
      search.descending = try descending(order.direction)
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
