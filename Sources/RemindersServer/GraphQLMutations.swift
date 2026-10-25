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
      "title": InputObjectField(type: GraphQLString, description: geofenceDescriptions["title"]),
      "latitude": InputObjectField(
        type: GraphQLNonNull(GraphQLFloat), description: geofenceDescriptions["latitude"]),
      "longitude": InputObjectField(
        type: GraphQLNonNull(GraphQLFloat), description: geofenceDescriptions["longitude"]),
      "radiusMeters": InputObjectField(
        type: GraphQLNonNull(GraphQLFloat), description: geofenceDescriptions["radiusMeters"]),
      "proximity": InputObjectField(
        type: GraphQLNonNull(proximity), description: geofenceDescriptions["proximity"]),
    ])
  let alarm = try GraphQLInputObjectType(
    name: "ReminderAlarmInput",
    fields: [
      "absoluteDate": InputObjectField(type: dateTime, description: "Trigger at this instant."),
      "relativeOffsetSeconds": InputObjectField(
        type: GraphQLFloat,
        description:
          "Seconds from the reminder's start date; negative means before. Requires a resulting start date."
      ),
      "geofence": InputObjectField(
        type: geofence, description: "Trigger on arrival at or departure from this region."),
    ])
  let recurrenceDay = try GraphQLInputObjectType(
    name: "RecurrenceDayInput",
    fields: [
      "day": InputObjectField(
        type: GraphQLNonNull(weekday), description: recurrenceDescriptions["day"]),
      "ordinal": InputObjectField(type: GraphQLInt, description: recurrenceDescriptions["ordinal"]),
    ])
  let recurrenceEnd = try GraphQLInputObjectType(
    name: "RecurrenceEndInput",
    fields: [
      "until": InputObjectField(type: dateTime, description: recurrenceDescriptions["until"]),
      "count": InputObjectField(type: GraphQLInt, description: recurrenceDescriptions["count"]),
    ])
  var recurrenceFields: InputObjectFieldMap = [
    "frequency": InputObjectField(
      type: GraphQLNonNull(frequency), description: recurrenceDescriptions["frequency"]),
    "interval": InputObjectField(
      type: GraphQLNonNull(GraphQLInt), description: recurrenceDescriptions["interval"]),
    "daysOfWeek": InputObjectField(
      type: GraphQLList(GraphQLNonNull(recurrenceDay)),
      description: recurrenceDescriptions["daysOfWeek"]),
    "end": InputObjectField(type: recurrenceEnd, description: recurrenceDescriptions["end"]),
  ]
  for key in ["daysOfMonth", "monthsOfYear", "weeksOfYear", "daysOfYear", "setPositions"] {
    recurrenceFields[key] = InputObjectField(
      type: GraphQLList(GraphQLNonNull(GraphQLInt)), description: recurrenceDescriptions[key])
  }
  let recurrence = try GraphQLInputObjectType(name: "RecurrenceRuleInput", fields: recurrenceFields)
  let clear = try GraphQLEnumType(
    name: "ReminderClearField",
    values: GraphQLEnumValueMap(
      uniqueKeysWithValues: ReminderClearValue.allCases.map {
        ($0.rawValue, GraphQLEnumValue(value: Map($0.rawValue), description: $0.description))
      }))
  // Create and patch inputs share types but describe their fields differently.
  let reminderTypes: [(String, GraphQLInputType)] = [
    ("name", GraphQLString), ("body", GraphQLString), ("priority", GraphQLInt),
    ("location", GraphQLString), ("url", GraphQLString), ("dueDate", dateTime),
    ("allDayDueDate", localDate), ("startDate", dateTime), ("allDayStartDate", localDate),
    ("timeZone", GraphQLString), ("flagged", GraphQLBoolean), ("remindMeDate", dateTime),
    ("alarms", GraphQLList(GraphQLNonNull(alarm))), ("recurrence", recurrence),
  ]
  func reminderFields(_ descriptions: [String: String]) -> InputObjectFieldMap {
    InputObjectFieldMap(
      uniqueKeysWithValues: reminderTypes.map {
        ($0.0, InputObjectField(type: $0.1, description: descriptions[$0.0]))
      })
  }
  let unsupportedStart =
    "Unsupported: date-only start writes are rejected because storage does not preserve them. Use startDate."
  let startDate =
    "The date and time at which work on the reminder starts. It cannot be later than the due date."
  let location = "Descriptive location text, separate from location-triggered alarms."
  let url = "An associated absolute URL; does not promise a rich-link preview in Reminders."
  var createFields = reminderFields([
    "alarms": "Alerts to configure; omission or an empty list configures no explicit alerts.",
    "allDayDueDate": "A date-only deadline; mutually exclusive with dueDate.",
    "allDayStartDate": unsupportedStart, "body": "Notes to attach to the reminder.",
    "dueDate": "A deadline including a time of day.",
    "flagged": "Whether to flag the new reminder.", "location": location,
    "priority": "Priority from 0 through 9.",
    "recurrence": "Repeating schedule; omission creates a non-repeating reminder.",
    "remindMeDate":
      "Date and time at which to remind the user; cannot be combined with alarms, start, due, or timeZone.",
    "startDate": startDate,
    "timeZone":
      "IANA time-zone identifier for the start and due dates, which requires at least one of them; omission stores timed dates in UTC.",
    "url": url,
  ])
  createFields["name"] = InputObjectField(
    type: GraphQLNonNull(GraphQLString), description: "Name of the new reminder.")
  createFields["listId"] = InputObjectField(
    type: GraphQLID,
    description: "Destination list; omission uses the default list. No default produces an error.")
  let create = try GraphQLInputObjectType(name: "CreateReminderInput", fields: createFields)
  var fields = reminderFields([
    "alarms": "Replace all configured alerts. An empty list removes all alerts.",
    "allDayDueDate": "Set a date-only deadline. Cannot be combined with dueDate.",
    "allDayStartDate": unsupportedStart,
    "body": "The new notes attached to the reminder. An empty string removes the notes.",
    "dueDate": "Set the due date and time. Cannot be combined with allDayDueDate.",
    "flagged": "Set whether the reminder is flagged, independently of priority.",
    "location": location, "name": "The new name of the reminder.",
    "priority": "Set the priority: 0 none, 1–4 high, 5 medium, or 6–9 low.",
    "recurrence": "Replace the repeating schedule. Use clearFields to stop repetition.",
    "remindMeDate":
      "Set the date and time at which to remind the user. Cannot be combined with date, time-zone, or alarm changes, or cleared.",
    "startDate": startDate,
    "timeZone":
      "Set an IANA time-zone identifier; requires a resulting start or due date. Use clearFields for floating/local interpretation.",
    "url": url,
  ])
  fields["completionDate"] = InputObjectField(
    type: dateTime,
    description:
      "Set the date and time the reminder was completed, which marks it completed. Cannot be combined with completed."
  )
  fields["completed"] = InputObjectField(
    type: GraphQLBoolean,
    description:
      "Whether to mark the reminder completed. Cannot be combined with completionDate changes.")
  // Nullable because GraphQLSwift rejects omitted non-null defaults in variables;
  // input validation still rejects explicit null.
  fields["clearFields"] = InputObjectField(
    type: GraphQLList(GraphQLNonNull(clear)), defaultValue: [],
    description:
      "Remove these values. Omission preserves them; explicit null is rejected. Do not set and clear the same field, or clear both forms of one date."
  )
  let patch = try GraphQLInputObjectType(name: "ReminderPatch", fields: fields)
  let deleted = try GraphQLObjectType(
    name: "DeleteResult",
    fields: [
      "deletedId": field(
        GraphQLNonNull(GraphQLID), description: "The deleted object's identifier.")
    ])
  let cleared = try GraphQLObjectType(
    name: "ClearCompletedResult",
    fields: [
      "listId": field(GraphQLNonNull(GraphQLID)),
      "deletedCount": field(GraphQLNonNull(GraphQLInt)),
    ])
  let listPatch = try GraphQLInputObjectType(
    name: "ListPatch",
    fields: [
      "name": InputObjectField(type: GraphQLString, description: "The new name of the list."),
      "color": InputObjectField(
        type: GraphQLString, description: "The new opaque sRGB list color: #RRGGBB or #RRGGBBFF."),
      "emblem": InputObjectField(
        type: GraphQLString, description: "The new emblem icon name for the list."),
    ])
  let createList = try GraphQLInputObjectType(
    name: "CreateListInput",
    fields: [
      "name": InputObjectField(
        type: GraphQLNonNull(GraphQLString), description: "Name of the new list."),
      "color": InputObjectField(
        type: GraphQLString, description: "Opaque sRGB list color: #RRGGBB or #RRGGBBFF."),
      "emblem": InputObjectField(type: GraphQLString, description: "Emblem icon name."),
      "accountId": InputObjectField(
        type: GraphQLNonNull(GraphQLID), description: "Account in which to create the list."),
    ])
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
          "Create a list. If a step after the save fails, the error has code WRITE_APPLIED and names the saved ID; do not retry creation blindly. Select id to retain it if response metadata fails.",
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
          "Update list properties. An error with code WRITE_APPLIED means the save succeeded before a later failure; refetch the saved ID before retrying.",
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
          "Create an incomplete reminder in an editable list. Omitted listId uses the application default. If a step after the save fails, the error has code WRITE_APPLIED and names the saved ID; do not retry creation blindly. Select id to retain it if response metadata fails.",
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
          "Update supplied fields. Null patch values are rejected; clearFields removes optional values. Dates can affect alerts. An error with code WRITE_APPLIED means the save succeeded before a later failure; refetch the saved ID before retrying.",
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
