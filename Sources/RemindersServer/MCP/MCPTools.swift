import Foundation
import MCP
import NIOHTTP1

private struct PageOutput<Item: Encodable>: Encodable {
  let items: [Item]
  let totalCount: Int
  let nextCursor: String?
  enum CodingKeys: String, CodingKey { case items, totalCount, nextCursor }
}
private struct AccountOutput: Encodable {
  let account: AccountRecord?
  enum CodingKeys: CodingKey { case account }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(account, forKey: .account)
  }
}
private struct AccountsOutput: Encodable {
  let items: [AccountRecord]
  enum CodingKeys: String, CodingKey { case items }
}
private struct SummaryOutput: Encodable {
  let items: [ListSummary]
  enum CodingKeys: String, CodingKey { case items }
}
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
private func describe(_ value: Value, _ text: String) -> Value {
  guard case .object(var object) = value else { return value }
  object["description"] = .string(text)
  return .object(object)
}
private func object(_ properties: [String: Value], required: [String] = []) -> Value {
  .object([
    "type": .string(JSONType.object.rawValue), "properties": .object(properties),
    "required": .array(required.map(Value.string)), "additionalProperties": false,
  ])
}
// An object schema whose property names are the coding keys of the type it describes,
// so the schema cannot name a field the encoder or decoder does not use.
private func schema<Key: CodingKey>(
  _: Key.Type, _ properties: KeyValuePairs<Key, Value>, required: [Key] = []
) -> Value {
  object(
    Dictionary(uniqueKeysWithValues: properties.map { ($0.key.stringValue, $0.value) }),
    required: required.map(\.stringValue))
}
// JSON Schema type names.
private enum JSONType: String { case object, array, string, integer, number, boolean, null }
// A value of one JSON type, with optional keywords such as minimum or default.
private func primitive(_ type: JSONType, _ keywords: [String: Value] = [:]) -> Value {
  .object(keywords.merging(["type": .string(type.rawValue)]) { _, type in type })
}
private func array(_ item: Value) -> Value {
  .object(["type": .string(JSONType.array.rawValue), "items": item])
}
private func enumeration(_ values: [String]) -> Value {
  primitive(.string, ["enum": .array(values.map(Value.string))])
}
private func nullable(_ value: Value) -> Value {
  .object(["anyOf": .array([value, primitive(.null)])])
}
private func toolsCatalog() -> [Tool] {
  let integer = primitive(.integer)
  let string = primitive(.string)
  let number = primitive(.number)
  let boolean = primitive(.boolean)
  let integers = array(integer)
  let components = schema(
    ComponentDate.CodingKeys.self,
    [
      .era: integer, .year: integer, .month: integer, .day: integer, .hour: integer,
      .minute: integer, .second: integer, .nanosecond: integer, .weekday: integer,
      .weekdayOrdinal: integer, .quarter: integer, .weekOfMonth: integer, .weekOfYear: integer,
      .yearForWeekOfYear: integer, .calendar: string, .timeZone: string, .isLeapMonth: boolean,
    ])
  let structuredLocation = schema(
    StructuredLocation.CodingKeys.self,
    [
      .title: describe(string, FieldDocs.StructuredLocation.title),
      .latitude: describe(number, FieldDocs.StructuredLocation.latitude),
      .longitude: describe(number, FieldDocs.StructuredLocation.longitude),
      .radius: describe(number, FieldDocs.StructuredLocation.radius),
    ], required: [.radius])
  let rawAlarm = schema(
    AlarmRecord.CodingKeys.self,
    [
      .absoluteDate: describe(string, FieldDocs.RawAlarm.absoluteDate),
      .relativeOffset: describe(number, FieldDocs.RawAlarm.relativeOffset),
      .proximity: describe(
        enumeration(["none", "enter", "leave", "unknown"]), FieldDocs.RawAlarm.proximity),
      .structuredLocation: describe(structuredLocation, FieldDocs.RawAlarm.structuredLocation),
    ], required: [.relativeOffset, .proximity])
  let geofence = schema(
    AlarmView.Geofence.CodingKeys.self,
    [
      .title: describe(string, FieldDocs.Geofence.title),
      .latitude: describe(number, FieldDocs.Geofence.latitude),
      .longitude: describe(number, FieldDocs.Geofence.longitude),
      .radiusMeters: describe(number, FieldDocs.Geofence.radiusMeters),
      .proximity: describe(
        enumeration(GeofenceProximity.allCases.map(\.rawValue)), FieldDocs.Geofence.proximity),
    ], required: [.latitude, .longitude, .radiusMeters, .proximity])
  let alarmKind = "The alarm's trigger type."
  let alarm = Value.object([
    "oneOf": .array([
      schema(
        AlarmView.CodingKeys.self,
        [
          .kind: describe(enumeration([AlarmKind.absolute.rawValue]), alarmKind),
          .at: describe(string, FieldDocs.AbsoluteAlarm.at),
        ], required: [.kind, .at]),
      schema(
        AlarmView.CodingKeys.self,
        [
          .kind: describe(enumeration([AlarmKind.relative.rawValue]), alarmKind),
          .offsetSeconds: describe(number, FieldDocs.RelativeAlarm.offsetSeconds),
        ], required: [.kind, .offsetSeconds]),
      schema(
        AlarmView.CodingKeys.self,
        [
          .kind: describe(enumeration([AlarmKind.location.rawValue]), alarmKind),
          .geofence: describe(geofence, FieldDocs.LocationAlarm.geofence),
        ], required: [.kind, .geofence]),
    ])
  ])
  // Reminder output and input use the same repeating-schedule shape.
  let rule = schema(
    RecurrenceView.CodingKeys.self,
    [
      .frequency: describe(
        enumeration(ScheduleFrequency.allCases.map(\.rawValue)), FieldDocs.Schedule.frequency),
      .interval: describe(integer, FieldDocs.Schedule.interval),
      .daysOfWeek: describe(
        array(
          schema(
            RecurrenceView.Day.CodingKeys.self,
            [
              .day: describe(
                enumeration(Weekday.allCases.map(\.rawValue)), FieldDocs.ScheduleDay.day),
              .ordinal: describe(integer, FieldDocs.ScheduleDay.ordinal),
            ], required: [.day])), FieldDocs.Schedule.daysOfWeek),
      .end: describe(
        schema(
          RecurrenceView.End.CodingKeys.self,
          [
            .until: describe(string, FieldDocs.ScheduleEnd.until),
            .count: describe(integer, FieldDocs.ScheduleEnd.count),
          ]), FieldDocs.Schedule.end),
      .daysOfMonth: describe(integers, FieldDocs.Schedule.daysOfMonth),
      .monthsOfYear: describe(integers, FieldDocs.Schedule.monthsOfYear),
      .weeksOfYear: describe(integers, FieldDocs.Schedule.weeksOfYear),
      .daysOfYear: describe(integers, FieldDocs.Schedule.daysOfYear),
      .setPositions: describe(integers, FieldDocs.Schedule.setPositions),
    ], required: [.frequency, .interval])
  let recurrenceRule = schema(
    RecurrenceRecord.CodingKeys.self,
    [
      .frequency: describe(
        enumeration(RecurrenceFrequency.allCases.map(\.rawValue)),
        FieldDocs.RecurrenceRule.frequency),
      .calendarIdentifier: describe(string, FieldDocs.RecurrenceRule.calendarIdentifier),
      .interval: describe(integer, FieldDocs.RecurrenceRule.interval),
      .firstDayOfTheWeek: describe(integer, FieldDocs.RecurrenceRule.firstDayOfTheWeek),
      .daysOfTheWeek: describe(
        array(
          schema(
            RecurrenceDay.CodingKeys.self,
            [
              .dayOfTheWeek: describe(integer, FieldDocs.RecurrenceDay.dayOfTheWeek),
              .weekNumber: describe(integer, FieldDocs.RecurrenceDay.weekNumber),
            ], required: [.dayOfTheWeek, .weekNumber])), FieldDocs.RecurrenceRule.daysOfTheWeek),
      .end: describe(
        schema(
          RecurrenceEnd.CodingKeys.self,
          [
            .endDate: describe(string, FieldDocs.RecurrenceEnd.endDate),
            .occurrenceCount: describe(integer, FieldDocs.RecurrenceEnd.occurrenceCount),
          ], required: [.occurrenceCount]), FieldDocs.RecurrenceRule.end),
      .daysOfTheMonth: describe(integers, FieldDocs.RecurrenceRule.daysOfTheMonth),
      .daysOfTheYear: describe(integers, FieldDocs.RecurrenceRule.daysOfTheYear),
      .weeksOfTheYear: describe(integers, FieldDocs.RecurrenceRule.weeksOfTheYear),
      .monthsOfTheYear: describe(integers, FieldDocs.RecurrenceRule.monthsOfTheYear),
      .setPositions: describe(integers, FieldDocs.RecurrenceRule.setPositions),
    ],
    required: [
      .frequency, .calendarIdentifier, .interval, .firstDayOfTheWeek, .daysOfTheWeek,
      .daysOfTheMonth, .daysOfTheYear, .weeksOfTheYear, .monthsOfTheYear, .setPositions,
    ])
  // A projection failure fails the whole MCP call, so projected fields say so in their own words.
  let item = schema(
    MCPReminder.CodingKeys.self,
    [
      .id: describe(string, FieldDocs.Reminder.id),
      .externalId: describe(
        string, "Identifier assigned by the account's server; unlike id, copies may share it."),
      .listId: describe(string, FieldDocs.Reminder.listId),
      .name: describe(string, FieldDocs.Reminder.name),
      .body: describe(string, FieldDocs.Reminder.body),
      .flagged: describe(
        boolean, "Set in reminders_create/reminders_update results when the write set flagged."),
      .completed: describe(boolean, FieldDocs.Reminder.completed),
      .priority: describe(integer, FieldDocs.Reminder.priority),
      .completionDate: describe(string, FieldDocs.Reminder.completionDate),
      .creationDate: describe(string, FieldDocs.Reminder.creationDate),
      .modificationDate: describe(string, FieldDocs.Reminder.modificationDate),
      .location: describe(string, FieldDocs.Reminder.location),
      .url: describe(string, FieldDocs.Reminder.url),
      .startDateComponents: describe(components, FieldDocs.Reminder.startDateComponents),
      .dueDateComponents: describe(components, FieldDocs.Reminder.dueDateComponents),
      .dueDay: describe(nullable(string), FieldDocs.Reminder.dueDay),
      .dueStatus: describe(
        enumeration(DueStatus.allCases.map(\.rawValue)), FieldDocs.Reminder.dueStatus),
      .rawAlarms: describe(array(rawAlarm), FieldDocs.Reminder.rawAlarms),
      .alarms: describe(
        array(alarm),
        "Configured alerts; an empty list means no alerts. rawAlarms holds the stored values."),
      .recurrenceRules: describe(array(recurrenceRule), FieldDocs.Reminder.recurrenceRules),
      .recurrence: describe(
        nullable(rule),
        "A single repeating schedule; null when no recurrence is configured. recurrenceRules holds the stored rules."
      ),
      .dueDate: describe(nullable(string), "The date and time by which the reminder is due."),
      .allDayDueDate: describe(nullable(string), FieldDocs.Reminder.allDayDueDate),
      .startDate: describe(
        nullable(string),
        "The date and time at which work on the reminder starts; Reminders may set it when a due date is set."
      ),
      .allDayStartDate: describe(nullable(string), FieldDocs.Reminder.allDayStartDate),
      .timeZone: describe(
        nullable(string),
        "IANA time-zone identifier, or null for floating/local date interpretation. Dates written in UTC report GMT."
      ),
    ],
    required: [
      .rawAlarms, .recurrence, .dueDate, .allDayDueDate, .startDate, .allDayStartDate, .timeZone,
      .id, .completed, .priority, .dueDay, .dueStatus, .alarms, .recurrenceRules,
    ])
  let list = schema(
    ListRecord.CodingKeys.self,
    [
      .id: describe(string, FieldDocs.ReminderList.id),
      .name: describe(string, FieldDocs.ReminderList.name),
      .color: describe(string, FieldDocs.ReminderList.color),
      .source: describe(
        schema(
          SourceRecord.CodingKeys.self,
          [
            .id: describe(string, FieldDocs.Account.id),
            .title: describe(string, FieldDocs.Account.name),
            .type: describe(
              integer,
              "EventKit source type: 0 local, 1 Exchange, 2 CalDAV including iCloud, 3 MobileMe, 4 subscribed, 5 birthdays."
            ),
          ], required: [.id, .title, .type]), "The account that owns the list."),
      .allowsContentModifications: describe(
        boolean, FieldDocs.ReminderList.allowsContentModifications),
      .allowsListModifications: describe(boolean, FieldDocs.ReminderList.allowsListModifications),
      .subscribed: describe(boolean, FieldDocs.ReminderList.subscribed),
    ],
    required: [
      .id, .name, .source, .allowsContentModifications, .allowsListModifications, .subscribed,
    ])
  let limit = describe(
    primitive(.integer, ["minimum": 1, "maximum": 100, "default": 50]),
    "Maximum number of items in the page.")
  let cursor = describe(
    primitive(.string, ["minLength": 1]),
    "Omit for the first page. Otherwise use nextCursor from the previous response with the same filter, orderBy, and limit. Each page reads live data, so concurrent changes can cause omissions or repeats."
  )
  let filterNote = "Search criteria; all given criteria must match."
  let orderNote = "Result order; without it, results use identifier order."
  let search = schema(
    ReminderSearchArguments.CodingKeys.self,
    [
      .limit: limit, .cursor: cursor,
      .orderBy: describe(
        schema(
          ReminderSearchArguments.Order.CodingKeys.self,
          [
            .field: describe(
              enumeration(ReminderSortField.allCases.map(\.rawValue)),
              FieldDocs.ReminderOrder.field),
            .direction: describe(
              enumeration(SortDirection.allCases.map(\.rawValue)),
              FieldDocs.ReminderOrder.direction),
          ], required: [.field]), orderNote),
      .filter: describe(
        schema(
          ReminderSearchArguments.Filter.CodingKeys.self,
          [
            .accountIds: describe(array(string), FieldDocs.ReminderFilter.accountIds),
            .listIds: describe(array(string), FieldDocs.ReminderFilter.listIds),
            .query: describe(string, FieldDocs.ReminderFilter.query),
            .dueFrom: describe(string, FieldDocs.ReminderFilter.dueFrom),
            .dueBefore: describe(string, FieldDocs.ReminderFilter.dueBefore),
            .dueOnOrAfter: describe(string, FieldDocs.ReminderFilter.dueOnOrAfter),
            .dueStatus: describe(
              enumeration(DueStatus.allCases.map(\.rawValue)), FieldDocs.ReminderFilter.dueStatus),
            .completed: describe(boolean, FieldDocs.ReminderFilter.completed),
            .hasDueDate: describe(boolean, FieldDocs.ReminderFilter.hasDueDate),
            .priorities: describe(
              array(primitive(.integer, ["minimum": 0, "maximum": 9])),
              FieldDocs.ReminderFilter.priorities),
          ]), filterNote),
    ])
  let listSearch = schema(
    ListSearchArguments.CodingKeys.self,
    [
      .limit: limit, .cursor: cursor,
      .filter: describe(
        schema(
          ListSearchArguments.Filter.CodingKeys.self,
          [
            .query: describe(string, FieldDocs.ListFilter.query),
            .accountIds: describe(array(string), FieldDocs.ListFilter.accountIds),
            .allowsContentModifications: describe(
              boolean, FieldDocs.ListFilter.allowsContentModifications),
            .subscribed: describe(boolean, FieldDocs.ListFilter.subscribed),
          ]), filterNote),
      .orderBy: describe(
        schema(
          ListSearchArguments.Order.CodingKeys.self,
          [
            .direction: describe(
              enumeration(SortDirection.allCases.map(\.rawValue)), FieldDocs.ListOrder.direction)
          ]), orderNote),
    ])
  let account = schema(
    AccountRecord.CodingKeys.self,
    [
      .id: describe(string, FieldDocs.Account.id),
      .name: describe(string, FieldDocs.Account.name),
    ], required: [.id, .name])
  let summary = schema(
    ListSummary.CodingKeys.self,
    [
      .listId: describe(string, "The list these counts describe."),
      .total: describe(integer, FieldDocs.ListSummary.total),
      .completed: describe(integer, FieldDocs.ListSummary.completed),
      .incomplete: describe(integer, FieldDocs.ListSummary.incomplete),
      .overdue: describe(integer, FieldDocs.ListSummary.overdue),
      .scheduled: describe(integer, FieldDocs.ListSummary.scheduled),
      .recurring: describe(integer, FieldDocs.ListSummary.recurring),
      .withAlarms: describe(integer, FieldDocs.ListSummary.withAlarms),
    ],
    required: [
      .total, .completed, .incomplete, .overdue, .scheduled, .recurring, .withAlarms, .listId,
    ])
  let annotations = Tool.Annotations(
    readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  let alarmInput = schema(
    AlarmInput.CodingKeys.self,
    [
      .absoluteDate: describe(string, FieldDocs.ReminderAlarmInput.absoluteDate),
      .relativeOffsetSeconds: describe(number, FieldDocs.ReminderAlarmInput.relativeOffsetSeconds),
      .geofence: describe(
        schema(
          GeofenceInput.CodingKeys.self,
          [
            .title: describe(string, FieldDocs.Geofence.title),
            .latitude: describe(
              primitive(.number, ["minimum": -90, "maximum": 90]),
              FieldDocs.Geofence.latitude),
            .longitude: describe(
              primitive(.number, ["minimum": -180, "maximum": 180]),
              FieldDocs.Geofence.longitude),
            .radiusMeters: describe(
              primitive(.number, ["minimum": 0]), FieldDocs.Geofence.radiusMeters),
            .proximity: describe(
              enumeration(GeofenceProximity.allCases.map(\.rawValue)),
              FieldDocs.Geofence.proximity),
          ], required: [.latitude, .longitude, .radiusMeters, .proximity]),
        FieldDocs.ReminderAlarmInput.geofence),
    ])
  let priority = primitive(.integer, ["minimum": 0, "maximum": 9])
  let createReminder = schema(
    ReminderInput.CodingKeys.self,
    [
      .listId: describe(string, FieldDocs.CreateReminderInput.listId),
      .name: describe(string, FieldDocs.CreateReminderInput.name),
      .body: describe(string, FieldDocs.CreateReminderInput.body),
      .location: describe(string, FieldDocs.CreateReminderInput.location),
      .url: describe(string, FieldDocs.CreateReminderInput.url),
      .dueDate: describe(string, FieldDocs.CreateReminderInput.dueDate),
      .allDayDueDate: describe(string, FieldDocs.CreateReminderInput.allDayDueDate),
      .startDate: describe(string, FieldDocs.CreateReminderInput.startDate),
      .allDayStartDate: describe(string, FieldDocs.CreateReminderInput.allDayStartDate),
      .timeZone: describe(string, FieldDocs.CreateReminderInput.timeZone),
      .remindMeDate: describe(string, FieldDocs.CreateReminderInput.remindMeDate),
      .priority: describe(priority, FieldDocs.CreateReminderInput.priority),
      .flagged: describe(boolean, FieldDocs.CreateReminderInput.flagged),
      .alarms: describe(array(alarmInput), FieldDocs.CreateReminderInput.alarms),
      .recurrence: describe(rule, FieldDocs.CreateReminderInput.recurrence),
    ], required: [.name])
  let reminderPatch = schema(
    ReminderInput.CodingKeys.self,
    [
      .name: describe(string, FieldDocs.ReminderPatch.name),
      .body: describe(string, FieldDocs.ReminderPatch.body),
      .location: describe(string, FieldDocs.ReminderPatch.location),
      .url: describe(string, FieldDocs.ReminderPatch.url),
      .dueDate: describe(string, FieldDocs.ReminderPatch.dueDate),
      .allDayDueDate: describe(string, FieldDocs.ReminderPatch.allDayDueDate),
      .startDate: describe(string, FieldDocs.ReminderPatch.startDate),
      .allDayStartDate: describe(string, FieldDocs.ReminderPatch.allDayStartDate),
      .timeZone: describe(string, FieldDocs.ReminderPatch.timeZone),
      .remindMeDate: describe(string, FieldDocs.ReminderPatch.remindMeDate),
      .completionDate: describe(string, FieldDocs.ReminderPatch.completionDate),
      .priority: describe(priority, FieldDocs.ReminderPatch.priority),
      .flagged: describe(boolean, FieldDocs.ReminderPatch.flagged),
      .completed: describe(boolean, FieldDocs.ReminderPatch.completed),
      .alarms: describe(array(alarmInput), FieldDocs.ReminderPatch.alarms),
      .recurrence: describe(rule, FieldDocs.ReminderPatch.recurrence),
      .clearFields: describe(
        array(enumeration(ReminderClearValue.allCases.map(\.rawValue))),
        FieldDocs.ReminderPatch.clearFields),
    ])
  let created = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
  let changed = Tool.Annotations(
    readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
  let listPatch = schema(
    ListInput.CodingKeys.self,
    [
      .name: describe(string, FieldDocs.ListPatch.name),
      .color: describe(string, FieldDocs.ListPatch.color),
      .emblem: describe(string, FieldDocs.ListPatch.emblem),
    ])
  let listCreate = schema(
    ListInput.CodingKeys.self,
    [
      .name: describe(string, FieldDocs.CreateListInput.name),
      .accountId: describe(string, FieldDocs.CreateListInput.accountId),
      .color: describe(string, FieldDocs.CreateListInput.color),
      .emblem: describe(string, FieldDocs.CreateListInput.emblem),
    ], required: [.name, .accountId])
  let nextCursorNote = "Pass as cursor to fetch the next page; absent on the last page."
  func byID(_ noun: String) -> Value {
    schema(
      IDArguments.CodingKeys.self, [.id: describe(string, "Identifier of the \(noun).")],
      required: [.id])
  }
  func patch<Changes: Decodable>(_: Changes.Type, _ noun: String, _ changes: Value) -> Value {
    schema(
      PatchArguments<Changes>.CodingKeys.self,
      [
        .id: describe(string, "Identifier of the \(noun)."),
        .patch: describe(changes, "The changes to make; omitted fields stay unchanged."),
      ], required: [.id, .patch])
  }
  func listResult(_ value: Value, _ text: String) -> Value {
    schema(ListOutput.CodingKeys.self, [.list: describe(value, text)], required: [.list])
  }
  func reminderResult(_ value: Value, _ text: String) -> Value {
    schema(GetOutput.CodingKeys.self, [.reminder: describe(value, text)], required: [.reminder])
  }
  func page<Item: Encodable>(_: Item.Type, _ item: Value, _ items: String, _ totalCount: String)
    -> Value
  {
    schema(
      PageOutput<Item>.CodingKeys.self,
      [
        .items: describe(array(item), items),
        .totalCount: describe(integer, totalCount),
        .nextCursor: describe(string, nextCursorNote),
      ], required: [.items, .totalCount])
  }
  let deleted = schema(
    DeletedReminder.CodingKeys.self,
    [.deletedId: describe(string, FieldDocs.DeleteResult.deletedId)], required: [.deletedId])
  let noArguments = object([:])
  let navigation = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  return [
    Tool(
      name: ToolName.listsCreate.rawValue,
      description:
        "Create a list in an explicit account. Colors use opaque #RRGGBB or #RRGGBBFF. Emblems are Reminders icon names. If the emblem write fails after the save, the error has code WRITE_APPLIED and names the saved ID; do not retry creation blindly.",
      inputSchema: listCreate, annotations: created,
      outputSchema: listResult(list, "The saved list.")),
    Tool(
      name: ToolName.listsUpdate.rawValue,
      description:
        "Update list name, color or emblem. Omitted values are unchanged; nulls and empty patches are invalid. If the emblem write fails after the save, the error has code WRITE_APPLIED and names the saved ID; refetch before retrying.",
      inputSchema: patch(ListInput.self, "list", listPatch), annotations: changed,
      outputSchema: listResult(list, "The saved list.")),
    Tool(
      name: ToolName.listsDelete.rawValue,
      description:
        "Delete a list. Nonempty lists require allowNonEmpty=true, which also deletes their reminders. The emptiness check does not lock out concurrent external edits.",
      inputSchema: schema(
        ListDeleteArguments.CodingKeys.self,
        [
          .id: describe(string, "Identifier of the list."),
          .allowNonEmpty: describe(
            primitive(.boolean, ["default": false]),
            "Also delete the list's reminders when it is not empty."),
        ], required: [.id]), annotations: changed,
      outputSchema: deleted),
    Tool(
      name: ToolName.remindersShow.rawValue,
      description: "Show a reminder in Reminders. Changes the application UI, not reminder data.",
      inputSchema: byID("reminder"), annotations: navigation,
      outputSchema: reminderResult(item, "The shown reminder.")),
    Tool(
      name: ToolName.listsShow.rawValue,
      description: "Show a list in Reminders. Changes the application UI, not list data.",
      inputSchema: byID("list"), annotations: navigation,
      outputSchema: listResult(list, "The shown list.")),
    Tool(
      name: ToolName.remindersCreate.rawValue,
      description:
        "Create an incomplete reminder. Specify listId or use the application's default list. Optional values must be omitted, not null. Timed/all-day due dates are exclusive; allDayStartDate is currently unsupported. Each alarm needs exactly one trigger; relative alarms require a start date. flagged and remindMeDate are applied after the reminder is saved; the result echoes flagged. A retry can create duplicates. A WRITE_APPLIED error means the save succeeded but a later step failed; refetch using the reported ID.",
      inputSchema: createReminder, annotations: created,
      outputSchema: reminderResult(item, "The saved reminder.")),
    Tool(
      name: ToolName.remindersUpdate.rawValue,
      description:
        "Patch a reminder by ID. Omitted fields are unchanged; null is invalid. At least one change is required. clearFields removes optional values; [] alone is not a change. Do not set and clear a property together, or combine completed and completionDate changes. alarms replaces all alerts; [] removes them. Dates can affect alerts. flagged and remindMeDate are applied after the reminder is saved; the result echoes flagged. A WRITE_APPLIED error means the save succeeded but a later step failed; refetch before retrying.",
      inputSchema: patch(ReminderInput.self, "reminder", reminderPatch), annotations: changed,
      outputSchema: reminderResult(item, "The saved reminder.")),
    Tool(
      name: ToolName.remindersDelete.rawValue,
      description:
        "Delete one reminder. Missing IDs return a NOT_FOUND tool error. Refetch before retrying after uncertain failures.",
      inputSchema: byID("reminder"), annotations: changed,
      outputSchema: deleted),
    Tool(
      name: ToolName.accountsGet.rawValue,
      description:
        "Read an account by identifier; returns null when it has no accessible reminder lists or is absent.",
      inputSchema: byID("account"), annotations: annotations,
      outputSchema: schema(
        AccountOutput.CodingKeys.self,
        [.account: describe(nullable(account), "The account, or null when absent.")],
        required: [.account])),
    Tool(
      name: ToolName.accountsList.rawValue,
      description: "Read accounts with accessible reminder lists, ordered by identifier.",
      inputSchema: noArguments, annotations: annotations,
      outputSchema: schema(
        AccountsOutput.CodingKeys.self,
        [.items: describe(array(account), "Accounts with accessible reminder lists.")],
        required: [.items])),
    Tool(
      name: ToolName.listsGet.rawValue,
      description:
        "Read a list by ID; absent identifiers return null. Emblems and containers are not included.",
      inputSchema: byID("list"), annotations: annotations,
      outputSchema: listResult(nullable(list), "The list, or null when absent.")),
    Tool(
      name: ToolName.defaultsGet.rawValue,
      description:
        "Read the accessible default list and its account; unavailable defaults return null.",
      inputSchema: noArguments, annotations: annotations,
      outputSchema: schema(
        DefaultsOutput.CodingKeys.self,
        [
          .list: describe(nullable(list), "The default list, or null when unavailable."),
          .account: describe(nullable(account), "The default list's account, or null."),
        ], required: [.list, .account])),
    Tool(
      name: ToolName.listsSummary.rawValue,
      description:
        "Count all reminders per accessible list, optionally restricted to listId. Counts overlap and include completed items except overdue.",
      inputSchema: schema(
        SummaryArguments.CodingKeys.self,
        [.listId: describe(string, "Count only this list; omit for every accessible list.")]),
      annotations: annotations,
      outputSchema: schema(
        SummaryOutput.CodingKeys.self,
        [.items: describe(array(summary), "Counts for each list.")], required: [.items])),
    Tool(
      name: ToolName.listsList.rawValue,
      description:
        "Read lists filtered by name, account IDs, editability, and subscription. Use filter for search criteria. orderBy.direction selects name ordering; omission uses identifier order. Filters intersect. Pagination uses limit and cursor; keep the criteria unchanged across pages. Name ordering is case-insensitive with ID ascending ties.",
      inputSchema: listSearch, annotations: annotations,
      outputSchema: page(
        ListRecord.self, list, FieldDocs.ListPage.items, FieldDocs.ListPage.totalCount)),
    Tool(
      name: ToolName.remindersSearch.rawValue,
      description:
        "Read reminders filtered by account/list IDs, completion, deadline presence, numeric priorities, due status and case-insensitive name-or-notes substring. Filters intersect; empty ID arrays match nothing. Supply criteria in filter. dueFrom and timestamp dueBefore bound deadline instants (inclusive/exclusive). All-day deadlines use midnight in their source zone. Calendar-day dueOnOrAfter and date-only dueBefore use reporting days; do not mix bound modes. orderBy supports NAME, DUE_DATE, PRIORITY, CREATION_DATE, MODIFICATION_DATE, COMPLETION_DATE with ASC/DESC, nulls last, and ID ascending ties. Omitted orderBy uses identifier order; priorities use numeric order. Cursor is the next page offset; keep criteria and limit unchanged across pages. Optional unavailable values are omitted. Dates retain their stored components; omitted hours mean date-only and omitted zones mean floating. A reminder whose dates, alarms, or recurrence cannot be projected fails the call. Flags, alert dates, containers, and emblems are not included.",
      inputSchema: search, annotations: annotations,
      outputSchema: page(
        MCPReminder.self, item, FieldDocs.ReminderPage.items, FieldDocs.ReminderPage.totalCount)),
    Tool(
      name: ToolName.remindersGet.rawValue,
      description:
        "Read one reminder with component and projected dates, alarms and recurrence; returns null when absent. Dates, alarms, or recurrence that cannot be projected fail the call. Flags, alert dates, containers, and emblems are not included.",
      inputSchema: byID("reminder"), annotations: annotations,
      outputSchema: reminderResult(nullable(item), "The reminder, or null when absent.")),
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
private func result<T: Encodable>(_ value: T) throws -> CallTool.Result {
  let bytes = try JSONEncoder().encode(value)
  return try .init(
    content: [.text(text: String(decoding: bytes, as: UTF8.self), annotations: nil, _meta: nil)],
    structuredContent: try JSONDecoder().decode(Value.self, from: bytes), isError: false)
}
// Tool names are the MCP contract; the catalog and dispatch both use these cases.
enum ToolName: String, CaseIterable {
  case listsCreate = "lists_create"
  case listsUpdate = "lists_update"
  case listsDelete = "lists_delete"
  case remindersShow = "reminders_show"
  case listsShow = "lists_show"
  case remindersCreate = "reminders_create"
  case remindersUpdate = "reminders_update"
  case remindersDelete = "reminders_delete"
  case accountsGet = "accounts_get"
  case accountsList = "accounts_list"
  case listsGet = "lists_get"
  case defaultsGet = "defaults_get"
  case listsSummary = "lists_summary"
  case listsList = "lists_list"
  case remindersSearch = "reminders_search"
  case remindersGet = "reminders_get"
}
private func callTool(_ tool: ToolName, _ params: CallTool.Parameters) async throws
  -> CallTool.Result
{
  let args = params.arguments ?? [:]
  try rejectNulls(.object(args))
  func arguments<T: Decodable>(_ type: T.Type) throws -> T { try decodeInput(type, from: args) }
  func noArguments() throws {
    guard args.isEmpty else { throw ServerError.invalidArgument("Unknown input field") }
  }
  func ids(_ field: InputField<[String]>, _ name: String) throws -> [String]? {
    guard let ids = field.value else { return nil }
    guard ids.allSatisfy({ !$0.isEmpty }) else {
      throw ServerError.invalidArgument("\(name) must contain nonempty identifiers")
    }
    return ids
  }
  // The page at the cursor offset; nextCursor is the following page's offset, and the
  // client keeps the criteria unchanged.
  func page<Item: Encodable>(
    _ items: [Item], limit: InputField<Int>, cursor: InputField<String>
  ) throws -> PageOutput<Item> {
    let limit = limit.value ?? 50
    guard (1...100).contains(limit) else {
      throw ServerError.invalidArgument("limit must be 1...100")
    }
    var offset = 0
    if let token = cursor.value {
      guard let value = Int(token), value >= 0 else {
        throw ServerError.invalidArgument(
          "cursor must be a nextCursor string from the previous response. Omit cursor for the first page."
        )
      }
      offset = value
    }
    let start = min(offset, items.count)
    let end = min(start + limit, items.count)
    return PageOutput(
      items: Array(items[start..<end]), totalCount: items.count,
      nextCursor: end < items.count ? String(end) : nil)
  }
  func savedReminder(_ request: ReminderWrite) async throws -> CallTool.Result {
    let saved = try await writeReminder(request)
    do { return try result(GetOutput(reminder: try MCPReminder(record: saved))) } catch {
      throw ServerError.writeApplied(
        "reminder \(saved.id) was saved, but response projection failed: \(error). Refetch before retrying."
      )
    }
  }
  func savedList(_ request: ListWrite) async throws -> CallTool.Result {
    let saved = try await writeList(request)
    do { return try result(ListOutput(list: saved)) } catch {
      throw ServerError.writeApplied(
        "list \(saved.id) was saved, but response projection failed: \(error). Refetch before retrying"
      )
    }
  }
  switch tool {
  case .remindersCreate:
    let input = try arguments(ReminderInput.self)
    return try await savedReminder(
      .create(listID: input.listId.value, changes: reminderChanges(input, creating: true)))
  case .remindersUpdate:
    let update = try arguments(PatchArguments<ReminderInput>.self)
    return try await savedReminder(
      .update(id: update.id, changes: reminderChanges(update.patch, creating: false)))
  case .listsCreate:
    let input = try arguments(ListInput.self)
    return try await savedList(
      .create(
        accountID: input.accountId.required("accountId"),
        changes: listChanges(input, creating: true)))
  case .listsUpdate:
    let update = try arguments(PatchArguments<ListInput>.self)
    return try await savedList(
      .update(id: update.id, changes: listChanges(update.patch, creating: false)))
  case .listsDelete:
    let delete = try arguments(ListDeleteArguments.self)
    let deleted = try await deleteList(
      id: delete.id, allowNonEmpty: delete.allowNonEmpty.value ?? false)
    return try result(deleted)
  case .remindersShow:
    let id = try arguments(IDArguments.self).id
    let shown = try await showReminder(id: id)
    do { return try result(GetOutput(reminder: try MCPReminder(record: shown))) } catch {
      throw ServerError.showApplied(
        "reminder \(id) was shown, but response projection failed: \(error)")
    }
  case .listsShow:
    let id = try arguments(IDArguments.self).id
    let shown = try await showList(id: id)
    do { return try result(ListOutput(list: shown)) } catch {
      throw ServerError.showApplied(
        "list \(id) was shown, but response projection failed: \(error)")
    }
  case .remindersDelete:
    let deleted = try await deleteReminder(id: arguments(IDArguments.self).id)
    return try result(deleted)
  case .accountsGet:
    let id = try arguments(IDArguments.self).id
    return try result(AccountOutput(account: await readLists().accounts.first { $0.id == id }))
  case .listsList:
    let search = try arguments(ListSearchArguments.self)
    var criteria = Search()
    if let filter = search.filter.value {
      criteria.query = filter.query.value
      criteria.accountIds = try ids(filter.accountIds, "accountIds")
      criteria.allowsContentModifications = filter.allowsContentModifications.value
      criteria.subscribed = filter.subscribed.value
    }
    if let order = search.orderBy.value {
      criteria.sortListsByName = true
      criteria.direction = order.direction.value ?? .ascending
    }
    return try await result(
      page(criteria.lists(readLists()), limit: search.limit, cursor: search.cursor))
  case .accountsList:
    try noArguments()
    return try result(AccountsOutput(items: await readLists().accounts))
  case .listsGet:
    return try result(ListOutput(list: await readList(id: arguments(IDArguments.self).id)))
  case .defaultsGet:
    try noArguments()
    let data = try await readLists()
    return try result(DefaultsOutput(list: data.defaultList, account: data.defaultAccount))
  case .listsSummary:
    let id = try arguments(SummaryArguments.self).listId.value
    let data = try await readRemindersData()
    return try result(
      SummaryOutput(
        items: data.lists.filter { id == nil || $0.id == id }.map {
          summarize(data, listId: $0.id)
        }))
  case .remindersGet:
    let id = try arguments(IDArguments.self).id
    return try result(
      GetOutput(reminder: await readReminder(id: id).map(MCPReminder.init(record:))))
  case .remindersSearch:
    let search = try arguments(ReminderSearchArguments.self)
    var criteria = Search()
    if let filter = search.filter.value {
      criteria.query = filter.query.value
      criteria.dueFrom = filter.dueFrom.value
      criteria.dueOnOrAfter = filter.dueOnOrAfter.value
      criteria.dueBefore = filter.dueBefore.value
      criteria.accountIds = try ids(filter.accountIds, "accountIds")
      criteria.listIds = try ids(filter.listIds, "listIds")
      criteria.hasDueDate = filter.hasDueDate.value
      criteria.completed = filter.completed.value
      if let priorities = filter.priorities.value {
        guard priorities.allSatisfy((0...9).contains) else {
          throw ServerError.invalidArgument("priorities must be 0...9")
        }
        criteria.priorities = priorities
      }
      if let value = filter.dueStatus.value {
        guard let status = DueStatus(rawValue: value) else {
          throw ServerError.invalidArgument("invalid dueStatus")
        }
        criteria.dueStatus = status
      }
    }
    if let order = search.orderBy.value {
      guard let field = ReminderSortField(rawValue: order.field) else {
        throw ServerError.invalidArgument("invalid order field")
      }
      criteria.reminderOrder = field
      criteria.direction = order.direction.value ?? .ascending
    }
    return try await result(
      page(
        criteria.reminders(readRemindersData()).map(MCPReminder.init(record:)), limit: search.limit,
        cursor: search.cursor))
  }
}
private let tools = toolsCatalog()
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

// The JSON-RPC method of a request body, for logging.
private func jsonRPCMethod(_ body: Data) -> String {
  switch try? JSONDecoder().decode(RPCEnvelope.self, from: body) {
  case .message(let method?, _): method
  case .batch: "batch"
  default: "unknown"
  }
}
// The JSON-RPC envelope fields the server logs; params and results stay undecoded.
private enum RPCEnvelope: Decodable {
  case message(method: String?, hasError: Bool)
  case batch
  enum CodingKeys: String, CodingKey { case method, error }
  init(from decoder: Decoder) throws {
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
      _ = try decoder.unkeyedContainer()
      self = .batch
      return
    }
    self = .message(
      method: try? c.decode(String.self, forKey: .method), hasError: c.contains(.error))
  }
}

// Records the tool outcome so the logger need not reparse large result bodies.
private final class ToolOutcome: @unchecked Sendable {
  var ran = false
  var failed = false
}
func handleMCP(
  method: HTTPMethod, headers: [String: String], body: Data,
  access: Capabilities.Access
) async throws -> ServiceResponse {
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
      guard let tool = ToolName(rawValue: params.name) else {
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
      do { return try await callTool(tool, params) } catch {
        outcome.failed = true
        return .init(
          content: [.text(text: errorText(error), annotations: nil, _meta: nil)], isError: true)
      }
    }
    try await server.start(transport: transport)
    let response = await transport.handleRequest(
      .init(method: method.rawValue, headers: headers, body: body, path: Route.mcp.rawValue))
    await server.stop()
    let responseBody = response.bodyData ?? Data()
    var failure: Failure? = outcome.failed ? .mcpTool : nil
    // Protocol replies (no tool or catalog handler ran) report errors in the JSON-RPC body.
    if !outcome.ran,
      case .message(_, hasError: true)? = try? JSONDecoder().decode(
        RPCEnvelope.self, from: responseBody)
    {
      failure = .mcpProtocol
    }
    var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
    if !headers.contains(name: "Content-Type") {
      headers.add(name: "Content-Type", value: "application/json")
    }
    return ServiceResponse(
      status: .init(statusCode: response.statusCode), headers: headers, body: responseBody,
      failure: failure,
      logMetadata: method == .POST ? ["rpc": jsonRPCMethod(body)] : [:])
  } catch {
    await server.stop()
    throw error
  }
}
