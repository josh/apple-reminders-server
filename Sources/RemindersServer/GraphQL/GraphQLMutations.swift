import Foundation
import GraphQL

// A write or navigation can change what this request already read, so the request's
// cached reads are dropped afterward, whether or not it succeeded.
private func afterWrite<T: Sendable>(
  _ context: (any Sendable)?, _ write: () async throws -> T
) async throws -> T {
  let value: T
  do { value = try await write() } catch {
    await (context as? GraphQLContext)?.invalidate()
    throw error
  }
  await (context as? GraphQLContext)?.invalidate()
  return value
}

// An input object's fields, named by the coding keys its decoder reads, in schema order.
private func inputFields<Key: CodingKey>(
  _: Key.Type, _ fields: KeyValuePairs<Key, InputObjectField>
) -> InputObjectFieldMap {
  InputObjectFieldMap(uniqueKeysWithValues: fields.map { ($0.key.stringValue, $0.value) })
}

func makeMutationType(
  reminder: GraphQLObjectType, list: GraphQLObjectType, dateTime: GraphQLScalarType,
  localDate: GraphQLScalarType, proximity: GraphQLEnumType, frequency: GraphQLEnumType,
  weekday: GraphQLEnumType
) throws -> GraphQLObjectType {
  let geofence = try GraphQLInputObjectType(
    name: "GeofenceInput",
    fields: inputFields(
      GeofenceInput.CodingKeys.self,
      [
        .title: InputObjectField(type: GraphQLString, description: FieldDocs.Geofence.title),
        .latitude: InputObjectField(
          type: GraphQLNonNull(GraphQLFloat), description: FieldDocs.Geofence.latitude),
        .longitude: InputObjectField(
          type: GraphQLNonNull(GraphQLFloat), description: FieldDocs.Geofence.longitude),
        .radiusMeters: InputObjectField(
          type: GraphQLNonNull(GraphQLFloat), description: FieldDocs.Geofence.radiusMeters),
        .proximity: InputObjectField(
          type: GraphQLNonNull(proximity), description: FieldDocs.Geofence.proximity),
      ]))
  let alarm = try GraphQLInputObjectType(
    name: "ReminderAlarmInput",
    fields: inputFields(
      AlarmInput.CodingKeys.self,
      [
        .absoluteDate: InputObjectField(
          type: dateTime, description: FieldDocs.ReminderAlarmInput.absoluteDate),
        .relativeOffsetSeconds: InputObjectField(
          type: GraphQLFloat, description: FieldDocs.ReminderAlarmInput.relativeOffsetSeconds),
        .geofence: InputObjectField(
          type: geofence, description: FieldDocs.ReminderAlarmInput.geofence),
      ]))
  let recurrenceDay = try GraphQLInputObjectType(
    name: "RecurrenceDayInput",
    fields: inputFields(
      RecurrenceInput.Day.CodingKeys.self,
      [
        .day: InputObjectField(
          type: GraphQLNonNull(weekday), description: FieldDocs.ScheduleDay.day),
        .ordinal: InputObjectField(type: GraphQLInt, description: FieldDocs.ScheduleDay.ordinal),
      ]))
  let recurrenceEnd = try GraphQLInputObjectType(
    name: "RecurrenceEndInput",
    fields: inputFields(
      RecurrenceInput.End.CodingKeys.self,
      [
        .until: InputObjectField(type: dateTime, description: FieldDocs.ScheduleEnd.until),
        .count: InputObjectField(type: GraphQLInt, description: FieldDocs.ScheduleEnd.count),
      ]))
  let selectors = GraphQLList(GraphQLNonNull(GraphQLInt))
  let recurrence = try GraphQLInputObjectType(
    name: "RecurrenceRuleInput",
    fields: inputFields(
      RecurrenceInput.CodingKeys.self,
      [
        .frequency: InputObjectField(
          type: GraphQLNonNull(frequency), description: FieldDocs.Schedule.frequency),
        .interval: InputObjectField(
          type: GraphQLNonNull(GraphQLInt), description: FieldDocs.Schedule.interval),
        .daysOfWeek: InputObjectField(
          type: GraphQLList(GraphQLNonNull(recurrenceDay)),
          description: FieldDocs.Schedule.daysOfWeek),
        .end: InputObjectField(type: recurrenceEnd, description: FieldDocs.Schedule.end),
        .daysOfMonth: InputObjectField(
          type: selectors, description: FieldDocs.Schedule.daysOfMonth),
        .monthsOfYear: InputObjectField(
          type: selectors, description: FieldDocs.Schedule.monthsOfYear),
        .weeksOfYear: InputObjectField(
          type: selectors, description: FieldDocs.Schedule.weeksOfYear),
        .daysOfYear: InputObjectField(type: selectors, description: FieldDocs.Schedule.daysOfYear),
        .setPositions: InputObjectField(
          type: selectors, description: FieldDocs.Schedule.setPositions),
      ]))
  let clear = try GraphQLEnumType(
    name: "ReminderClearField",
    values: GraphQLEnumValueMap(
      uniqueKeysWithValues: ReminderClearValue.allCases.map {
        ($0.rawValue, GraphQLEnumValue(value: Map($0.rawValue), description: $0.description))
      }))
  let alarms = GraphQLList(GraphQLNonNull(alarm))
  typealias Create = FieldDocs.CreateReminderInput
  let create = try GraphQLInputObjectType(
    name: "CreateReminderInput",
    fields: inputFields(
      ReminderInput.CodingKeys.self,
      [
        .name: InputObjectField(type: GraphQLNonNull(GraphQLString), description: Create.name),
        .body: InputObjectField(type: GraphQLString, description: Create.body),
        .priority: InputObjectField(type: GraphQLInt, description: Create.priority),
        .location: InputObjectField(type: GraphQLString, description: Create.location),
        .url: InputObjectField(type: GraphQLString, description: Create.url),
        .dueDate: InputObjectField(type: dateTime, description: Create.dueDate),
        .allDayDueDate: InputObjectField(type: localDate, description: Create.allDayDueDate),
        .startDate: InputObjectField(type: dateTime, description: Create.startDate),
        .allDayStartDate: InputObjectField(type: localDate, description: Create.allDayStartDate),
        .timeZone: InputObjectField(type: GraphQLString, description: Create.timeZone),
        .flagged: InputObjectField(type: GraphQLBoolean, description: Create.flagged),
        .remindMeDate: InputObjectField(type: dateTime, description: Create.remindMeDate),
        .alarms: InputObjectField(type: alarms, description: Create.alarms),
        .recurrence: InputObjectField(type: recurrence, description: Create.recurrence),
        .listId: InputObjectField(type: GraphQLID, description: Create.listId),
      ]))
  typealias Patch = FieldDocs.ReminderPatch
  let patch = try GraphQLInputObjectType(
    name: "ReminderPatch",
    fields: inputFields(
      ReminderInput.CodingKeys.self,
      [
        .name: InputObjectField(type: GraphQLString, description: Patch.name),
        .body: InputObjectField(type: GraphQLString, description: Patch.body),
        .priority: InputObjectField(type: GraphQLInt, description: Patch.priority),
        .location: InputObjectField(type: GraphQLString, description: Patch.location),
        .url: InputObjectField(type: GraphQLString, description: Patch.url),
        .dueDate: InputObjectField(type: dateTime, description: Patch.dueDate),
        .allDayDueDate: InputObjectField(type: localDate, description: Patch.allDayDueDate),
        .startDate: InputObjectField(type: dateTime, description: Patch.startDate),
        .allDayStartDate: InputObjectField(type: localDate, description: Patch.allDayStartDate),
        .timeZone: InputObjectField(type: GraphQLString, description: Patch.timeZone),
        .flagged: InputObjectField(type: GraphQLBoolean, description: Patch.flagged),
        .remindMeDate: InputObjectField(type: dateTime, description: Patch.remindMeDate),
        .alarms: InputObjectField(type: alarms, description: Patch.alarms),
        .recurrence: InputObjectField(type: recurrence, description: Patch.recurrence),
        .completionDate: InputObjectField(type: dateTime, description: Patch.completionDate),
        .completed: InputObjectField(type: GraphQLBoolean, description: Patch.completed),
        // Nullable because GraphQLSwift rejects omitted non-null defaults in variables;
        // input validation still rejects explicit null.
        .clearFields: InputObjectField(
          type: GraphQLList(GraphQLNonNull(clear)), defaultValue: [],
          description: Patch.clearFields),
      ]))
  let deleted = try GraphQLObjectType(
    name: "DeleteResult",
    fields: [
      "deletedId": field(
        GraphQLNonNull(GraphQLID), \DeletedReminder.deletedId,
        description: FieldDocs.DeleteResult.deletedId)
    ])
  let cleared = try GraphQLObjectType(
    name: "ClearCompletedResult",
    fields: [
      "listId": field(
        GraphQLNonNull(GraphQLID), \ClearCompletedResult.listId,
        description: "The list whose completed reminders were deleted."),
      "deletedCount": field(
        GraphQLNonNull(GraphQLInt), \ClearCompletedResult.deletedCount,
        description: "Number of completed reminders deleted."),
    ])
  let listPatch = try GraphQLInputObjectType(
    name: "ListPatch",
    fields: inputFields(
      ListInput.CodingKeys.self,
      [
        .name: InputObjectField(type: GraphQLString, description: FieldDocs.ListPatch.name),
        .color: InputObjectField(type: GraphQLString, description: FieldDocs.ListPatch.color),
        .emblem: InputObjectField(type: GraphQLString, description: FieldDocs.ListPatch.emblem),
      ]))
  let createList = try GraphQLInputObjectType(
    name: "CreateListInput",
    fields: inputFields(
      ListInput.CodingKeys.self,
      [
        .name: InputObjectField(
          type: GraphQLNonNull(GraphQLString), description: FieldDocs.CreateListInput.name),
        .color: InputObjectField(
          type: GraphQLString, description: FieldDocs.CreateListInput.color),
        .emblem: InputObjectField(
          type: GraphQLString, description: FieldDocs.CreateListInput.emblem),
        .accountId: InputObjectField(
          type: GraphQLNonNull(GraphQLID), description: FieldDocs.CreateListInput.accountId),
      ]))
  return try GraphQLObjectType(
    name: "Mutation",
    fields: [
      "createList": GraphQLField(
        type: list,
        description:
          "Create a list. If a step after the save fails, the error has code WRITE_APPLIED and names the saved ID; do not retry creation blindly. Select id to retain it if response metadata fails.",
        args: ["input": GraphQLArgument(type: GraphQLNonNull(createList))],
        resolve: { _, args, context, _ in
          let input = try decodeInput(GraphQLCreateArguments<ListInput>.self, from: args).input
          return try await afterWrite(context) {
            try await writeList(
              .create(
                accountID: input.accountId.required("accountId"),
                changes: listChanges(input, creating: true)))
          }
        }),
      "updateList": GraphQLField(
        type: list,
        description:
          "Update list properties. An error with code WRITE_APPLIED means the save succeeded before a later failure; refetch the saved ID before retrying.",
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "patch": GraphQLArgument(type: GraphQLNonNull(listPatch)),
        ],
        resolve: { _, args, context, _ in
          let update = try decodeInput(GraphQLPatchArguments<ListInput>.self, from: args)
          return try await afterWrite(context) {
            try await writeList(
              .update(id: update.id, changes: listChanges(update.patch, creating: false)))
          }
        }),
      "deleteList": GraphQLField(
        type: deleted,
        description:
          "Delete a list; nonempty lists require allowNonEmpty. Concurrent external edits are not locked.",
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "allowNonEmpty": GraphQLArgument(
            type: GraphQLNonNull(GraphQLBoolean), defaultValue: false),
        ],
        resolve: { _, args, context, _ in
          let delete = try decodeInput(GraphQLListDeleteArguments.self, from: args)
          return try await afterWrite(context) {
            try await deleteList(id: delete.id, allowNonEmpty: delete.allowNonEmpty)
          }
        }),
      "showReminder": GraphQLField(
        type: reminder,
        description: "Show a reminder in the Reminders UI without changing its data.",
        args: ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
        resolve: { _, args, context, _ in
          let id = try decodeInput(GraphQLIDArguments.self, from: args).id
          return try await afterWrite(context) { try await showReminder(id: id) }
        }),
      "showList": GraphQLField(
        type: list, description: "Show a list in the Reminders UI without changing its data.",
        args: ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
        resolve: { _, args, context, _ in
          let id = try decodeInput(GraphQLIDArguments.self, from: args).id
          return try await afterWrite(context) { try await showList(id: id) }
        }),
      "createReminder": GraphQLField(
        type: reminder,
        description:
          "Create an incomplete reminder in an editable list. Omitted listId uses the application default. If a step after the save fails, the error has code WRITE_APPLIED and names the saved ID; do not retry creation blindly. Select id to retain it if response metadata fails.",
        args: ["input": GraphQLArgument(type: GraphQLNonNull(create))],
        resolve: { _, args, context, _ in
          let input = try decodeInput(GraphQLCreateArguments<ReminderInput>.self, from: args).input
          return try await afterWrite(context) {
            try await writeReminder(
              .create(listID: input.listId.value, changes: reminderChanges(input, creating: true)))
          }
        }),
      "updateReminder": GraphQLField(
        type: reminder,
        description:
          "Update supplied fields. Null patch values are rejected; clearFields removes optional values. Dates can affect alerts. An error with code WRITE_APPLIED means the save succeeded before a later failure; refetch the saved ID before retrying.",
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "patch": GraphQLArgument(type: GraphQLNonNull(patch)),
        ],
        resolve: { _, args, context, _ in
          let update = try decodeInput(GraphQLPatchArguments<ReminderInput>.self, from: args)
          return try await afterWrite(context) {
            try await writeReminder(
              .update(id: update.id, changes: reminderChanges(update.patch, creating: false)))
          }
        }),
      "clearCompletedReminders": GraphQLField(
        type: cleared,
        description:
          "Delete completed reminders in one list. Keep incomplete reminders and the list.",
        args: ["listId": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
        resolve: { _, args, context, _ in
          let listID = try decodeInput(GraphQLClearCompletedArguments.self, from: args).listId
          return try await afterWrite(context) { try await clearCompletedReminders(listID: listID) }
        }),
      "deleteReminder": GraphQLField(
        type: deleted,
        description:
          "Delete a reminder in an editable list. Missing identifiers return a NOT_FOUND error.",
        args: ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
        resolve: { _, args, context, _ in
          let id = try decodeInput(GraphQLIDArguments.self, from: args).id
          return try await afterWrite(context) { try await deleteReminder(id: id) }
        }),
    ])
}
