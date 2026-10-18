import Foundation
import GraphQL

func makeMutationType(
  reminder: GraphQLObjectType, list: GraphQLObjectType, dateTime: GraphQLScalarType,
  localDate: GraphQLScalarType, proximity: GraphQLEnumType, frequency: GraphQLEnumType,
  weekday: GraphQLEnumType,
  invalidate: @escaping @Sendable ((any Sendable)?) async -> Void
) throws -> GraphQLObjectType {
  let geofence = try GraphQLInputObjectType(
    name: "GeofenceInput",
    fields: [
      "title": InputObjectField(type: GraphQLString),
      "latitude": InputObjectField(type: GraphQLNonNull(GraphQLFloat)),
      "longitude": InputObjectField(type: GraphQLNonNull(GraphQLFloat)),
      "radiusMeters": InputObjectField(type: GraphQLNonNull(GraphQLFloat)),
      "proximity": InputObjectField(type: GraphQLNonNull(proximity)),
    ])
  let alarm = try GraphQLInputObjectType(
    name: "ReminderAlarmInput",
    fields: [
      "absoluteDate": InputObjectField(type: dateTime),
      "relativeOffsetSeconds": InputObjectField(type: GraphQLFloat),
      "geofence": InputObjectField(type: geofence),
    ])
  var fields: InputObjectFieldMap = [
    "name": InputObjectField(type: GraphQLString), "body": InputObjectField(type: GraphQLString),
    "priority": InputObjectField(type: GraphQLInt),
    "location": InputObjectField(type: GraphQLString), "url": InputObjectField(type: GraphQLString),
    "dueDate": InputObjectField(type: dateTime), "allDayDueDate": InputObjectField(type: localDate),
    "startDate": InputObjectField(type: dateTime),
    "allDayStartDate": InputObjectField(type: localDate),
  ]
  fields["timeZone"] = InputObjectField(type: GraphQLString)
  fields["flagged"] = InputObjectField(type: GraphQLBoolean)
  fields["remindMeDate"] = InputObjectField(type: dateTime)
  fields["alarms"] = InputObjectField(type: GraphQLList(GraphQLNonNull(alarm)))
  let recurrenceDay = try GraphQLInputObjectType(
    name: "RecurrenceDayInput",
    fields: [
      "day": InputObjectField(type: GraphQLNonNull(weekday)),
      "ordinal": InputObjectField(type: GraphQLInt),
    ])
  let recurrenceEnd = try GraphQLInputObjectType(
    name: "RecurrenceEndInput",
    fields: [
      "until": InputObjectField(type: dateTime), "count": InputObjectField(type: GraphQLInt),
    ])
  var recurrenceFields: InputObjectFieldMap = [
    "frequency": InputObjectField(type: GraphQLNonNull(frequency)),
    "interval": InputObjectField(type: GraphQLNonNull(GraphQLInt)),
    "daysOfWeek": InputObjectField(type: GraphQLList(GraphQLNonNull(recurrenceDay))),
    "end": InputObjectField(type: recurrenceEnd),
  ]
  for key in ["daysOfMonth", "monthsOfYear", "weeksOfYear", "daysOfYear", "setPositions"] {
    recurrenceFields[key] = InputObjectField(type: GraphQLList(GraphQLNonNull(GraphQLInt)))
  }
  fields["recurrence"] = InputObjectField(
    type: try GraphQLInputObjectType(name: "RecurrenceRuleInput", fields: recurrenceFields))
  var createFields = fields
  createFields["name"] = InputObjectField(type: GraphQLNonNull(GraphQLString))
  createFields["listId"] = InputObjectField(type: GraphQLID)
  let create = try GraphQLInputObjectType(name: "CreateReminderInput", fields: createFields)
  let clear = try GraphQLEnumType(
    name: "ReminderClearField",
    values: GraphQLEnumValueMap(
      uniqueKeysWithValues: ReminderClearValue.allCases.map {
        ($0.rawValue, GraphQLEnumValue(value: Map($0.rawValue)))
      }))
  fields["completionDate"] = InputObjectField(type: dateTime)
  fields["completed"] = InputObjectField(type: GraphQLBoolean)
  // Nullable because GraphQLSwift rejects omitted non-null defaults in variables;
  // input validation still rejects explicit null.
  fields["clearFields"] = InputObjectField(
    type: GraphQLList(GraphQLNonNull(clear)), defaultValue: [])
  let patch = try GraphQLInputObjectType(name: "ReminderPatch", fields: fields)
  let deleted = try GraphQLObjectType(
    name: "DeleteResult", fields: ["deletedId": field(GraphQLNonNull(GraphQLID))])
  let cleared = try GraphQLObjectType(
    name: "ClearCompletedResult",
    fields: [
      "listId": field(GraphQLNonNull(GraphQLID)),
      "deletedCount": field(GraphQLNonNull(GraphQLInt)),
    ])
  let listPatchFields: InputObjectFieldMap = [
    "name": InputObjectField(type: GraphQLString), "color": InputObjectField(type: GraphQLString),
    "emblem": InputObjectField(type: GraphQLString),
  ]
  let listPatch = try GraphQLInputObjectType(name: "ListPatch", fields: listPatchFields)
  var createListFields = listPatchFields
  createListFields["name"] = InputObjectField(type: GraphQLNonNull(GraphQLString))
  createListFields["accountId"] = InputObjectField(type: GraphQLNonNull(GraphQLID))
  let createList = try GraphQLInputObjectType(name: "CreateListInput", fields: createListFields)
  @Sendable func runList(_ request: ListMutation, context: (any Sendable)?) async throws -> Map {
    do {
      let value = try graphMap(await mutateList(request))
      await invalidate(context)
      return value
    } catch {
      await invalidate(context)
      throw error
    }
  }
  @Sendable func run(_ request: ReminderMutation, context: (any Sendable)?) async throws -> Map {
    do {
      let value = try graphMap(await mutateReminder(request))
      await invalidate(context)
      return value
    } catch {
      await invalidate(context)
      throw error
    }
  }
  return try GraphQLObjectType(
    name: "Mutation",
    fields: [
      "createList": GraphQLField(
        type: list,
        description:
          "Create a list. WRITE_APPLIED includes the saved ID if a later step fails; do not retry creation blindly. Select id to retain it if response metadata fails.",
        args: ["input": GraphQLArgument(type: GraphQLNonNull(createList))],
        resolve: { _, args, context, _ in
          let input = try mutationInput(args["input"])
          return try await runList(
            .create(
              accountID: input["accountId"].stringValue(),
              changes: listChanges(input, creating: true)), context: context)
        }),
      "updateList": GraphQLField(
        type: list,
        description:
          "Update list properties. WRITE_APPLIED means a save succeeded before a later failure; refetch the saved ID before retrying.",
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "patch": GraphQLArgument(type: GraphQLNonNull(listPatch)),
        ],
        resolve: { _, args, context, _ in
          try await runList(
            .update(
              id: args["id"].stringValue(),
              changes: listChanges(mutationInput(args["patch"]), creating: false)), context: context
          )
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
          try await runList(
            .delete(id: args["id"].stringValue(), allowNonEmpty: args["allowNonEmpty"].boolValue()),
            context: context)
        }),
      "showReminder": GraphQLField(
        type: reminder,
        description: "Show a reminder in the Reminders UI without changing its data.",
        args: ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
        resolve: { _, args, context, _ in
          let value = try await showRemindersObject(
            args["id"].stringValue(), isList: false)
          await invalidate(context)
          return try graphMap(value)
        }),
      "showList": GraphQLField(
        type: list, description: "Show a list in the Reminders UI without changing its data.",
        args: ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
        resolve: { _, args, context, _ in
          let value = try await showRemindersObject(
            args["id"].stringValue(), isList: true)
          await invalidate(context)
          return try graphMap(value)
        }),
      "createReminder": GraphQLField(
        type: reminder,
        description:
          "Create an incomplete reminder in an editable list. Omitted listId uses the application default. WRITE_APPLIED includes the saved ID if a later step fails; do not retry creation blindly. Select id to retain it if response metadata fails.",
        args: ["input": GraphQLArgument(type: GraphQLNonNull(create))],
        resolve: { _, args, context, _ in
          let input = args["input"]
          return try await run(
            .create(
              listID: try? input["listId"].stringValue(),
              changes: reminderChanges(mutationInput(input), creating: true)), context: context)
        }),
      "updateReminder": GraphQLField(
        type: reminder,
        description:
          "Update supplied fields. Null patch values are rejected; clearFields removes optional values. Dates can affect alerts. WRITE_APPLIED means a save succeeded before a later failure; refetch the saved ID before retrying.",
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "patch": GraphQLArgument(type: GraphQLNonNull(patch)),
        ],
        resolve: { _, args, context, _ in
          try await run(
            .update(
              id: args["id"].stringValue(),
              changes: reminderChanges(mutationInput(args["patch"]), creating: false)),
            context: context)
        }),
      "clearCompletedReminders": GraphQLField(
        type: cleared,
        description:
          "Delete completed reminders in one list. Keep incomplete reminders and the list.",
        args: ["listId": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
        resolve: { _, args, context, _ in
          do {
            let result = try await clearCompletedReminders(listID: args["listId"].stringValue())
            await invalidate(context)
            return try graphMap(result)
          } catch {
            await invalidate(context)
            throw error
          }
        }),
      "deleteReminder": GraphQLField(
        type: deleted,
        description:
          "Delete a reminder in an editable list. Missing identifiers return a NOT_FOUND error.",
        args: ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
        resolve: { _, args, context, _ in
          try await run(.delete(id: args["id"].stringValue()), context: context)
        }),
    ])
}
