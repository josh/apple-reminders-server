import Foundation
import GraphQL

// Resolvers receive the Swift record their parent field returned.
func record<Source>(_ source: any Sendable, as _: Source.Type) throws -> Source {
  guard let value = source as? Source else {
    throw ServerError.internalError("Unexpected GraphQL source; expected \(Source.self)")
  }
  return value
}
func field<Source, Value: Sendable>(
  _ type: GraphQLOutputType, _ value: @escaping @Sendable (Source) throws -> Value,
  description: String? = nil
) -> GraphQLField {
  GraphQLField(
    type: type, description: description,
    resolve: { source, _, _, _ in try value(record(source, as: Source.self)) })
}
private func requestContext(_ context: (any Sendable)?) throws -> GraphQLContext {
  guard let context = context as? GraphQLContext else {
    throw ServerError.internalError("Missing GraphQL request context")
  }
  return context
}
private func remindersData(_ context: (any Sendable)?) async throws -> RemindersData {
  try await requestContext(context).remindersData()
}
private func searchPage(
  _ data: RemindersData, args: Map, context: (any Sendable)?, scope: Set<String>? = nil
) async throws -> GraphQLPage<ReminderRecord> {
  let arguments = try decodeInput(GraphQLReminderSearch.self, from: args)
  let filter = arguments.filter.value
  var search = Search()
  if let filter {
    search.query = filter.query.value
    search.nameContains = filter.nameContains.value
    search.accountIds = filter.accountIds.value
    search.listIds = filter.listIds.value
    search.hasDueDate = filter.hasDueDate.value
    search.completed = filter.completed.value
    search.priorities = filter.priorities.value
    // Enum values are the uppercase names; records store lowercase statuses.
    search.dueStatus = filter.dueStatus.value.flatMap { DueStatus(rawValue: $0.lowercased()) }
    search.dueOnOrAfter = filter.dueOnOrAfter.value
    search.dueBefore = filter.dueBefore.value
    search.dueFrom = filter.dueFrom.value
  }
  if let order = arguments.orderBy.value {
    search.reminderOrder = ReminderSortField(rawValue: order.field)
    search.direction = order.direction.value ?? .ascending
  }
  var items = try search.reminders(data, scope: scope)
  // Flags come from Reminders automation, so the flag filter applies only here.
  if let flagged = filter?.flagged.value {
    let flags = try await requestContext(context).flags()
    // An unknown flag (not yet exposed by Reminders) matches neither filter value.
    items = items.filter { flags[$0.id] == flagged }
  }
  return try page(items, limit: arguments.limit, offset: arguments.offset)
}
struct PageInfo: Sendable {
  let offset, limit: Int
  let hasNextPage, hasPreviousPage: Bool
}
struct GraphQLPage<Item: Sendable>: Sendable {
  let items: [Item]
  let totalCount: Int
  let pageInfo: PageInfo
}
func page<Item: Sendable>(_ values: [Item], limit: Int, offset: Int) throws -> GraphQLPage<Item> {
  guard (1...100).contains(limit), offset >= 0 else {
    throw ServerError.invalidArgument("limit must be 1...100 and offset must be nonnegative")
  }
  let start = min(offset, values.count)
  let end = min(start + limit, values.count)
  return GraphQLPage(
    items: Array(values[start..<end]), totalCount: values.count,
    pageInfo: PageInfo(
      offset: offset, limit: limit, hasNextPage: end < values.count,
      hasPreviousPage: offset > 0 && !values.isEmpty))
}

// One cache per HTTP execution, shared by item fields and root aliases. A Task
// caches failures as well as successes and coalesces concurrent resolver calls.
actor GraphQLContext {
  func invalidate() {
    data = nil
    lookup = nil
    emblems = nil
    alerts = nil
    listContainers = nil
    reminderContainers = nil
  }
  // One automation read per property per request; each maps object UUIDs to values.
  private var emblems: Task<[String: String?], Error>?
  private var alerts: Task<[String: String?], Error>?
  private var listContainers: Task<[String: ContainerReference], Error>?
  private var reminderContainers: Task<[String: ContainerReference], Error>?
  func emblem(listID: String) async throws -> String? {
    if emblems == nil { emblems = Task { try await readProperty(.emblems) } }
    return try await Self.value(in: emblems!, id: listID)
  }
  func remindMeDate(reminderID: String) async throws -> String? {
    if alerts == nil { alerts = Task { try await readProperty(.alerts) } }
    return try await Self.value(in: alerts!, id: reminderID)
  }
  func container(listID: String) async throws -> ContainerReference {
    if listContainers == nil { listContainers = Task { try await readProperty(.listContainers) } }
    return try await Self.value(in: listContainers!, id: listID)
  }
  func container(reminderID: String) async throws -> ContainerReference {
    if reminderContainers == nil {
      reminderContainers = Task { try await readProperty(.reminderContainers) }
    }
    return try await Self.value(in: reminderContainers!, id: reminderID)
  }
  private static func value<Value>(in read: Task<[String: Value], Error>, id: String) async throws
    -> Value
  {
    let values = try await read.value
    guard let key = UUID(uuidString: id)?.uuidString, let value = values[key] else {
      throw ServerError.internalError("No matching automation object; reminders may have changed")
    }
    return value
  }
  private var lookup: Task<[String: Bool], Error>?
  private var data: Task<RemindersData, Error>?
  func remindersData() async throws -> RemindersData {
    if data == nil { data = Task { try await readRemindersData() } }
    return try await data!.value
  }
  func flags() async throws -> [String: Bool] {
    if lookup == nil {
      lookup = Task {
        let table = try await readProperty(.flags)
        var flags: [String: Bool] = [:]
        for item in try await remindersData().reminders {
          if let value = UUID(uuidString: item.id).flatMap({ table[$0.uuidString] }) {
            flags[item.id] = value
          }
        }
        return flags
      }
    }
    return try await lookup!.value
  }
  func flag(id: String) async throws -> Bool? {
    let flags = try await flags()
    guard let value = flags[id] else {
      throw ServerError.internalError(
        "Reminders has not yet exposed this reminder to automation; flagged is unknown, retry later"
      )
    }
    return value
  }
}

private let automationNote =
  "Read through Reminders automation, which may need Automation permission."

func makeSchema() throws -> GraphQLSchema {
  let account = try GraphQLObjectType(
    name: "Account",
    fields: [
      "id": field(GraphQLNonNull(GraphQLID), \AccountRecord.id, description: FieldDocs.Account.id),
      "name": field(GraphQLString, \AccountRecord.name, description: FieldDocs.Account.name),
    ])
  let list = try GraphQLObjectType(
    name: "ReminderList",
    fields: [
      "id": field(
        GraphQLNonNull(GraphQLID), \ListRecord.id, description: FieldDocs.ReminderList.id),
      "name": field(GraphQLString, \ListRecord.name, description: FieldDocs.ReminderList.name),
      "allowsContentModifications": field(
        GraphQLBoolean, \ListRecord.allowsContentModifications,
        description: FieldDocs.ReminderList.allowsContentModifications),
      "allowsListModifications": field(
        GraphQLBoolean, \ListRecord.allowsListModifications,
        description: FieldDocs.ReminderList.allowsListModifications),
      "subscribed": field(
        GraphQLBoolean, \ListRecord.subscribed, description: FieldDocs.ReminderList.subscribed),
      "color": field(GraphQLString, \ListRecord.color, description: FieldDocs.ReminderList.color),
      "emblem": GraphQLField(
        type: GraphQLString,
        description:
          "The emblem icon name displayed beside the list. \(automationNote)",
        resolve: { source, _, context, _ in
          try await requestContext(context).emblem(listID: record(source, as: ListRecord.self).id)
        }),
    ])
  let dateTime = try GraphQLScalarType(
    name: "DateTime", description: "RFC 3339 timestamp with an explicit offset, serialized in UTC.",
    // Every output date comes from timestamp() and is already canonical UTC.
    serialize: { value in
      guard let text = value as? String else {
        throw ServerError.internalError("DateTime output is not a string")
      }
      return .string(text)
    },
    parseValue: { value in
      _ = try parseTimestamp(value.stringValue())
      return value
    },
    parseLiteral: { node in
      let value = try valueFromASTUntyped(valueAST: node)
      _ = try parseTimestamp(value.stringValue())
      return value
    })
  let localDate = try GraphQLScalarType(
    name: "LocalDate", description: "Calendar date in YYYY-MM-DD form, without a time or offset.")
  let url = try GraphQLScalarType(name: "URL", description: "Absolute URL serialized as a string.")

  let components = try GraphQLObjectType(
    name: "DateComponents",
    description:
      "Stored calendar components; null fields are unset. An hour marks a timed date, and a null timeZone means floating.",
    fields: [
      "era": field(GraphQLInt, \ComponentDate.era),
      "year": field(GraphQLInt, \ComponentDate.year),
      "month": field(GraphQLInt, \ComponentDate.month),
      "day": field(GraphQLInt, \ComponentDate.day),
      "hour": field(GraphQLInt, \ComponentDate.hour),
      "minute": field(GraphQLInt, \ComponentDate.minute),
      "second": field(GraphQLInt, \ComponentDate.second),
      "nanosecond": field(GraphQLInt, \ComponentDate.nanosecond),
      "weekday": field(GraphQLInt, \ComponentDate.weekday),
      "weekdayOrdinal": field(GraphQLInt, \ComponentDate.weekdayOrdinal),
      "quarter": field(GraphQLInt, \ComponentDate.quarter),
      "weekOfMonth": field(GraphQLInt, \ComponentDate.weekOfMonth),
      "weekOfYear": field(GraphQLInt, \ComponentDate.weekOfYear),
      "yearForWeekOfYear": field(GraphQLInt, \ComponentDate.yearForWeekOfYear),
      "calendar": field(GraphQLString, \ComponentDate.calendar),
      "timeZone": field(GraphQLString, \ComponentDate.timeZone),
      "isLeapMonth": field(GraphQLBoolean, \ComponentDate.isLeapMonth),
    ])
  func enumeration(_ name: String, _ values: [String], descriptions: [String: String] = [:])
    throws -> GraphQLEnumType
  {
    try GraphQLEnumType(
      name: name,
      values: GraphQLEnumValueMap(
        uniqueKeysWithValues: values.map {
          (
            $0.uppercased(),
            GraphQLEnumValue(value: .string($0), description: descriptions[$0.uppercased()])
          )
        }))
  }
  let dueStatus = try enumeration(
    "DueStatus", DueStatus.allCases.map { $0.rawValue.uppercased() },
    descriptions: [
      "OVERDUE": "A timed deadline has passed, or an all-day deadline is before today.",
      "TODAY": "The deadline falls today and has not passed.",
      "FUTURE": "The deadline falls after today.", "UNSCHEDULED": "No due date.",
      "UNKNOWN": "The due date cannot be classified.",
    ])
  let direction = try enumeration(
    "SortDirection", SortDirection.allCases.map(\.rawValue),
    descriptions: ["ASC": "Smallest or earliest first.", "DESC": "Largest or latest first."])
  let orderField = try enumeration(
    "ReminderSortField", ReminderSortField.allCases.map(\.rawValue),
    descriptions: [
      "NAME": "Reminder name.", "DUE_DATE": "Timed or all-day deadline.",
      "PRIORITY": "Numeric priority.", "CREATION_DATE": "Creation timestamp.",
      "MODIFICATION_DATE": "Last modification timestamp.",
      "COMPLETION_DATE": "Completion timestamp.",
    ])
  let reminderOrder = try GraphQLInputObjectType(
    name: "ReminderOrder",
    fields: [
      "field": InputObjectField(
        type: GraphQLNonNull(orderField), description: FieldDocs.ReminderOrder.field),
      "direction": InputObjectField(
        type: direction, defaultValue: "ASC", description: FieldDocs.ReminderOrder.direction),
    ])
  let listOrder = try GraphQLInputObjectType(
    name: "ListOrder",
    fields: [
      "direction": InputObjectField(
        type: direction, defaultValue: "ASC", description: FieldDocs.ListOrder.direction)
    ])
  let listFilter = try GraphQLInputObjectType(
    name: "ListFilter",
    fields: [
      "query": InputObjectField(
        type: GraphQLString, description: FieldDocs.ListFilter.query),
      "accountIds": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLID)), description: FieldDocs.ListFilter.accountIds),
      "allowsContentModifications": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.ListFilter.allowsContentModifications),
      "subscribed": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.ListFilter.subscribed),
    ])
  let structuredLocation = try GraphQLObjectType(
    name: "StructuredLocation",
    fields: [
      "title": field(
        GraphQLString, \StructuredLocation.title, description: FieldDocs.StructuredLocation.title),
      "latitude": field(
        GraphQLFloat, \StructuredLocation.latitude,
        description: FieldDocs.StructuredLocation.latitude),
      "longitude": field(
        GraphQLFloat, \StructuredLocation.longitude,
        description: FieldDocs.StructuredLocation.longitude),
      "radius": field(
        GraphQLNonNull(GraphQLFloat), \StructuredLocation.radius,
        description: FieldDocs.StructuredLocation.radius),
    ])
  let alarm = try GraphQLObjectType(
    name: "RawAlarm",
    description: "An alarm exactly as stored.",
    fields: [
      "absoluteDate": field(
        dateTime, \AlarmRecord.absoluteDate, description: FieldDocs.RawAlarm.absoluteDate),
      "relativeOffset": field(
        GraphQLNonNull(GraphQLFloat), \AlarmRecord.relativeOffset,
        description: FieldDocs.RawAlarm.relativeOffset),
      "proximity": field(
        GraphQLNonNull(GraphQLString), { (alarm: AlarmRecord) in alarm.proximity.rawValue },
        description: FieldDocs.RawAlarm.proximity),
      "structuredLocation": field(
        structuredLocation, \AlarmRecord.structuredLocation,
        description: FieldDocs.RawAlarm.structuredLocation),
    ])
  let proximity = try enumeration(
    "GeofenceProximity", GeofenceProximity.allCases.map(\.rawValue),
    descriptions: [
      "ARRIVE": "Trigger when entering the region.", "DEPART": "Trigger when leaving the region.",
    ])
  let geofence = try GraphQLObjectType(
    name: "Geofence",
    fields: [
      "title": field(
        GraphQLString, \AlarmView.Geofence.title, description: FieldDocs.Geofence.title),
      "latitude": field(
        GraphQLNonNull(GraphQLFloat), \AlarmView.Geofence.latitude,
        description: FieldDocs.Geofence.latitude),
      "longitude": field(
        GraphQLNonNull(GraphQLFloat), \AlarmView.Geofence.longitude,
        description: FieldDocs.Geofence.longitude),
      "radiusMeters": field(
        GraphQLNonNull(GraphQLFloat), \AlarmView.Geofence.radiusMeters,
        description: FieldDocs.Geofence.radiusMeters),
      "proximity": field(
        GraphQLNonNull(proximity),
        { (geofence: AlarmView.Geofence) in geofence.proximity.rawValue },
        description: FieldDocs.Geofence.proximity),
    ])
  let absoluteAlarm = try GraphQLObjectType(
    name: AlarmKind.absolute.rawValue,
    fields: [
      "at": field(GraphQLNonNull(dateTime), \AlarmView.at, description: FieldDocs.AbsoluteAlarm.at)
    ])
  let relativeAlarm = try GraphQLObjectType(
    name: AlarmKind.relative.rawValue,
    fields: [
      "offsetSeconds": field(
        GraphQLNonNull(GraphQLFloat), \AlarmView.offsetSeconds,
        description: FieldDocs.RelativeAlarm.offsetSeconds)
    ])
  let locationAlarm = try GraphQLObjectType(
    name: AlarmKind.location.rawValue,
    fields: [
      "geofence": field(
        GraphQLNonNull(geofence), \AlarmView.geofence, description: FieldDocs.LocationAlarm.geofence
      )
    ])
  let alarmUnion = try GraphQLUnionType(
    name: "ReminderAlarm",
    resolveType: { value, _ in try record(value, as: AlarmView.self).kind.rawValue },
    types: [absoluteAlarm, relativeAlarm, locationAlarm])
  let recurrenceDay = try GraphQLObjectType(
    name: "RecurrenceDay",
    fields: [
      "dayOfTheWeek": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceDay.dayOfTheWeek,
        description: FieldDocs.RecurrenceDay.dayOfTheWeek),
      "weekNumber": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceDay.weekNumber,
        description: FieldDocs.RecurrenceDay.weekNumber),
    ])
  let recurrenceEnd = try GraphQLObjectType(
    name: "RecurrenceEnd",
    fields: [
      "endDate": field(
        dateTime, \RecurrenceEnd.endDate, description: FieldDocs.RecurrenceEnd.endDate),
      "occurrenceCount": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceEnd.occurrenceCount,
        description: FieldDocs.RecurrenceEnd.occurrenceCount),
    ])
  let integers = GraphQLNonNull(GraphQLList(GraphQLNonNull(GraphQLInt)))
  let recurrence = try GraphQLObjectType(
    name: "RecurrenceRule", description: "A recurrence rule exactly as stored.",
    fields: [
      "frequency": field(
        GraphQLNonNull(GraphQLString), { (rule: RecurrenceRecord) in rule.frequency.rawValue },
        description: FieldDocs.RecurrenceRule.frequency),
      "calendarIdentifier": field(
        GraphQLNonNull(GraphQLString), \RecurrenceRecord.calendarIdentifier,
        description: FieldDocs.RecurrenceRule.calendarIdentifier),
      "interval": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceRecord.interval,
        description: FieldDocs.RecurrenceRule.interval),
      "firstDayOfTheWeek": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceRecord.firstDayOfTheWeek,
        description: FieldDocs.RecurrenceRule.firstDayOfTheWeek),
      "daysOfTheWeek": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(recurrenceDay))), \RecurrenceRecord.daysOfTheWeek,
        description: FieldDocs.RecurrenceRule.daysOfTheWeek),
      "end": field(recurrenceEnd, \RecurrenceRecord.end, description: FieldDocs.RecurrenceRule.end),
      "daysOfTheMonth": field(
        integers, \RecurrenceRecord.daysOfTheMonth,
        description: FieldDocs.RecurrenceRule.daysOfTheMonth),
      "daysOfTheYear": field(
        integers, \RecurrenceRecord.daysOfTheYear,
        description: FieldDocs.RecurrenceRule.daysOfTheYear),
      "weeksOfTheYear": field(
        integers, \RecurrenceRecord.weeksOfTheYear,
        description: FieldDocs.RecurrenceRule.weeksOfTheYear),
      "monthsOfTheYear": field(
        integers, \RecurrenceRecord.monthsOfTheYear,
        description: FieldDocs.RecurrenceRule.monthsOfTheYear),
      "setPositions": field(
        integers, \RecurrenceRecord.setPositions,
        description: FieldDocs.RecurrenceRule.setPositions),
    ])
  let frequency = try enumeration(
    "RecurrenceFrequency", ScheduleFrequency.allCases.map(\.rawValue),
    descriptions: [
      "DAILY": "Repeat in day intervals.", "WEEKLY": "Repeat in week intervals.",
      "MONTHLY": "Repeat in month intervals.", "YEARLY": "Repeat in year intervals.",
    ])
  let weekday = try enumeration(
    "Weekday", Weekday.allCases.map(\.rawValue),
    descriptions: Dictionary(
      uniqueKeysWithValues: Weekday.allCases.map { ($0.rawValue, $0.rawValue.capitalized + ".") }))
  let scheduleDay = try GraphQLObjectType(
    name: "ReminderRecurrenceDay",
    fields: [
      "day": field(
        GraphQLNonNull(weekday), { (day: RecurrenceView.Day) in day.day.rawValue },
        description: FieldDocs.ScheduleDay.day),
      "ordinal": field(
        GraphQLInt, \RecurrenceView.Day.ordinal, description: FieldDocs.ScheduleDay.ordinal),
    ])
  let scheduleEnd = try GraphQLObjectType(
    name: "ReminderRecurrenceEnd",
    fields: [
      "until": field(dateTime, \RecurrenceView.End.until, description: FieldDocs.ScheduleEnd.until),
      "count": field(
        GraphQLInt, \RecurrenceView.End.count, description: FieldDocs.ScheduleEnd.count),
    ])
  let selectors = GraphQLList(GraphQLNonNull(GraphQLInt))
  let schedule = try GraphQLObjectType(
    name: "ReminderRecurrence",
    fields: [
      "frequency": field(
        GraphQLNonNull(frequency), { (rule: RecurrenceView) in rule.frequency.rawValue },
        description: FieldDocs.Schedule.frequency),
      "interval": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceView.interval,
        description: FieldDocs.Schedule.interval),
      "daysOfWeek": field(
        GraphQLList(GraphQLNonNull(scheduleDay)), \RecurrenceView.daysOfWeek,
        description: FieldDocs.Schedule.daysOfWeek),
      "end": field(scheduleEnd, \RecurrenceView.end, description: FieldDocs.Schedule.end),
      "daysOfMonth": field(
        selectors, \RecurrenceView.daysOfMonth, description: FieldDocs.Schedule.daysOfMonth),
      "monthsOfYear": field(
        selectors, \RecurrenceView.monthsOfYear, description: FieldDocs.Schedule.monthsOfYear),
      "weeksOfYear": field(
        selectors, \RecurrenceView.weeksOfYear, description: FieldDocs.Schedule.weeksOfYear),
      "daysOfYear": field(
        selectors, \RecurrenceView.daysOfYear, description: FieldDocs.Schedule.daysOfYear),
      "setPositions": field(
        selectors, \RecurrenceView.setPositions, description: FieldDocs.Schedule.setPositions),
    ])
  let filter = try GraphQLInputObjectType(
    name: "ReminderFilter",
    fields: [
      "query": InputObjectField(
        type: GraphQLString, description: FieldDocs.ReminderFilter.query),
      "accountIds": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLID)),
        description: FieldDocs.ReminderFilter.accountIds),
      "flagged": InputObjectField(
        type: GraphQLBoolean,
        description:
          "Match flagged or unflagged reminders. Uses Reminders automation; a failed read fails the collection."
      ),
      "hasDueDate": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.ReminderFilter.hasDueDate),
      "dueFrom": InputObjectField(
        type: dateTime, description: FieldDocs.ReminderFilter.dueFrom),
      "listIds": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLID)), description: FieldDocs.ReminderFilter.listIds),
      "priorities": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLInt)),
        description: FieldDocs.ReminderFilter.priorities),
      "dueStatus": InputObjectField(
        type: dueStatus, description: FieldDocs.ReminderFilter.dueStatus),
      "dueOnOrAfter": InputObjectField(
        type: GraphQLString, description: FieldDocs.ReminderFilter.dueOnOrAfter),
      "dueBefore": InputObjectField(
        type: GraphQLString, description: FieldDocs.ReminderFilter.dueBefore),
      "completed": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.ReminderFilter.completed),
      "nameContains": InputObjectField(
        type: GraphQLString, description: "Case-insensitive substring of the reminder name."),
    ])
  let reminder = try GraphQLObjectType(
    name: "Reminder",
    fields: [
      "id": field(
        GraphQLNonNull(GraphQLID), \ReminderRecord.id, description: FieldDocs.Reminder.id),
      "name": field(GraphQLString, \ReminderRecord.name, description: FieldDocs.Reminder.name),
      "body": field(GraphQLString, \ReminderRecord.body, description: FieldDocs.Reminder.body),
      "completed": field(
        GraphQLBoolean, \ReminderRecord.completed, description: FieldDocs.Reminder.completed),
      "priority": field(
        GraphQLInt, \ReminderRecord.priority, description: FieldDocs.Reminder.priority),
      "creationDate": field(
        dateTime, \ReminderRecord.creationDate, description: FieldDocs.Reminder.creationDate),
      "completionDate": field(
        dateTime, \ReminderRecord.completionDate, description: FieldDocs.Reminder.completionDate),
      "modificationDate": field(
        dateTime, \ReminderRecord.modificationDate,
        description: FieldDocs.Reminder.modificationDate),
      "location": field(
        GraphQLString, \ReminderRecord.location, description: FieldDocs.Reminder.location),
      "dueDay": field(
        GraphQLString, \ReminderRecord.dueDay, description: FieldDocs.Reminder.dueDay),
      "listId": field(GraphQLID, \ReminderRecord.listId, description: FieldDocs.Reminder.listId),
      "url": field(url, \ReminderRecord.url, description: FieldDocs.Reminder.url),
      "startDateComponents": field(
        components, \ReminderRecord.startDateComponents,
        description: FieldDocs.Reminder.startDateComponents),
      "dueDateComponents": field(
        components, \ReminderRecord.dueDateComponents,
        description: FieldDocs.Reminder.dueDateComponents),
      // Enum values match their uppercase names; records store lowercase statuses.
      "dueStatus": field(
        GraphQLNonNull(dueStatus),
        { (item: ReminderRecord) in item.dueStatus.rawValue.uppercased() },
        description: FieldDocs.Reminder.dueStatus),
      "rawAlarms": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(alarm))), \ReminderRecord.alarms,
        description: FieldDocs.Reminder.rawAlarms),
      "alarms": field(
        GraphQLList(GraphQLNonNull(alarmUnion)),
        { (item: ReminderRecord) in try item.alarms.map(AlarmView.init) },
        description:
          "Configured alerts. An empty list means no alerts; null indicates a read failure or a trigger this union cannot represent, and rawAlarms holds the stored values."
      ),
      "recurrenceRules": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(recurrence))), \ReminderRecord.recurrenceRules,
        description: FieldDocs.Reminder.recurrenceRules),
      "recurrence": field(
        schedule, { (item: ReminderRecord) in try recurrenceView(item.recurrenceRules) },
        description:
          "A single repeating schedule; null when no recurrence is configured. Multiple rules produce a field error, and recurrenceRules holds the stored rules."
      ),
      "flagged": GraphQLField(
        type: GraphQLBoolean,
        description:
          "Whether the reminder is flagged. This is independent of its priority. \(automationNote)",
        resolve: { source, _, context, _ in
          try await requestContext(context).flag(id: record(source, as: ReminderRecord.self).id)
        }),
      "remindMeDate": GraphQLField(
        type: dateTime,
        description:
          "The date and time at which to remind the user; Reminders may set it to the due date and time. \(automationNote)",
        resolve: { source, _, context, _ in
          try await requestContext(context).remindMeDate(
            reminderID: record(source, as: ReminderRecord.self).id)
        }),
      "dueDate": calendarField(
        dateTime, \ReminderRecord.dueDateComponents, timed: true,
        description:
          "The date and time by which the reminder is due. Unsupported components produce a field error; dueDateComponents holds the stored value."
      ),
      "startDate": calendarField(
        dateTime, \ReminderRecord.startDateComponents, timed: true,
        description:
          "The date and time at which work on the reminder starts; Reminders may set it when a due date is set. Unsupported components produce a field error; startDateComponents holds the stored value."
      ),
      "allDayDueDate": calendarField(
        localDate, \ReminderRecord.dueDateComponents, timed: false,
        description: FieldDocs.Reminder.allDayDueDate),
      "allDayStartDate": calendarField(
        localDate, \ReminderRecord.startDateComponents, timed: false,
        description: FieldDocs.Reminder.allDayStartDate),
      "timeZone": field(
        GraphQLString,
        { (item: ReminderRecord) -> String? in
          let due = item.dueDateComponents
          let start = item.startDateComponents
          if let due, let start, due.timeZone != start.timeZone {
            throw ServerError.unsupported(
              "start and due dates use different time zones; inspect component fields")
          }
          return due?.timeZone ?? start?.timeZone
        },
        description:
          "IANA time-zone identifier, or null for floating/local date interpretation. Dates written in UTC report GMT. Different start and due zones produce a field error."
      ),
    ])
  let pageInfo = try GraphQLObjectType(
    name: "PageInfo",
    fields: [
      "offset": field(
        GraphQLNonNull(GraphQLInt), \PageInfo.offset, description: "Requested zero-based offset."),
      "limit": field(
        GraphQLNonNull(GraphQLInt), \PageInfo.limit, description: "Requested maximum page size."),
      "hasNextPage": field(
        GraphQLNonNull(GraphQLBoolean), \PageInfo.hasNextPage,
        description: "Whether results exist after this page."),
      "hasPreviousPage": field(
        GraphQLNonNull(GraphQLBoolean), \PageInfo.hasPreviousPage,
        description: "Whether matching results exist before the requested offset."),
    ])
  func pageType<Item: Sendable>(
    _ name: String, _ item: GraphQLObjectType, of _: Item.Type, items: String, totalCount: String
  ) throws -> GraphQLObjectType {
    try GraphQLObjectType(
      name: name,
      fields: [
        "items": field(
          GraphQLNonNull(GraphQLList(GraphQLNonNull(item))), \GraphQLPage<Item>.items,
          description: items),
        "totalCount": field(
          GraphQLNonNull(GraphQLInt), \GraphQLPage<Item>.totalCount, description: totalCount),
        "pageInfo": field(
          GraphQLNonNull(pageInfo), \GraphQLPage<Item>.pageInfo,
          description: "Position and availability of neighboring pages."),
      ])
  }
  let pageArgs: GraphQLArgumentConfigMap = [
    "limit": GraphQLArgument(type: GraphQLNonNull(GraphQLInt), defaultValue: 50),
    "offset": GraphQLArgument(type: GraphQLNonNull(GraphQLInt), defaultValue: 0),
  ]
  var listArgs = pageArgs
  listArgs["filter"] = GraphQLArgument(type: listFilter)
  listArgs["orderBy"] = GraphQLArgument(type: listOrder)
  var reminderArgs = pageArgs
  reminderArgs["orderBy"] = GraphQLArgument(type: reminderOrder)
  reminderArgs["filter"] = GraphQLArgument(type: filter)
  let idArg: GraphQLArgumentConfigMap = ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))]
  let listPage = try pageType(
    "ListPage", list, of: ListRecord.self, items: FieldDocs.ListPage.items,
    totalCount: FieldDocs.ListPage.totalCount)
  let reminderPage = try pageType(
    "ReminderPage", reminder, of: ReminderRecord.self, items: FieldDocs.ReminderPage.items,
    totalCount: FieldDocs.ReminderPage.totalCount)
  let summary = try GraphQLObjectType(
    name: "ListSummary",
    fields: [
      "total": field(
        GraphQLNonNull(GraphQLInt), \ListSummary.total, description: FieldDocs.ListSummary.total),
      "completed": field(
        GraphQLNonNull(GraphQLInt), \ListSummary.completed,
        description: FieldDocs.ListSummary.completed),
      "incomplete": field(
        GraphQLNonNull(GraphQLInt), \ListSummary.incomplete,
        description: FieldDocs.ListSummary.incomplete),
      "overdue": field(
        GraphQLNonNull(GraphQLInt), \ListSummary.overdue,
        description: FieldDocs.ListSummary.overdue),
      "scheduled": field(
        GraphQLNonNull(GraphQLInt), \ListSummary.scheduled,
        description: FieldDocs.ListSummary.scheduled),
      "recurring": field(
        GraphQLNonNull(GraphQLInt), \ListSummary.recurring,
        description: FieldDocs.ListSummary.recurring),
      "withAlarms": field(
        GraphQLNonNull(GraphQLInt), \ListSummary.withAlarms,
        description: FieldDocs.ListSummary.withAlarms),
    ])
  let resolveContainer: GraphQLTypeResolve = { value, _ in
    switch value {
    case is AccountRecord: return account
    case is ListRecord: return list
    case is ReminderRecord: return reminder
    default: throw ServerError.internalError("Unexpected container value")
    }
  }
  let listContainer = try GraphQLUnionType(
    name: "ListContainer", resolveType: resolveContainer, types: [account, list])
  let reminderContainer = try GraphQLUnionType(
    name: "ReminderContainer", resolveType: resolveContainer, types: [list, reminder])
  func containerField<Source>(
    _ type: GraphQLUnionType,
    reference: @escaping @Sendable (GraphQLContext, Source) async throws -> ContainerReference,
    description: String
  ) -> GraphQLField {
    GraphQLField(
      type: type, description: description,
      resolve: { source, _, context, _ in
        let context = try requestContext(context)
        let reference = try await reference(context, record(source, as: Source.self))
        let data = try await context.remindersData()
        func matches(_ id: String) -> Bool {
          id.caseInsensitiveCompare(reference.id) == .orderedSame
        }
        let container: (any Sendable)?
        switch reference.kind {
        case .account: container = data.accounts.first { matches($0.id) }
        case .list: container = data.lists.first { matches($0.id) }
        case .reminder: container = data.reminders.first { matches($0.id) }
        }
        guard let container else {
          throw ServerError.internalError(
            "Container is outside the accessible reminders or changed during the read")
        }
        return container
      })
  }
  var accountFields = try account.fields()
  accountFields["lists"] = GraphQLField(
    type: listPage, description: "Lists in this account; filters apply within it.", args: listArgs,
    resolve: { source, args, context, _ in
      let id = try record(source, as: AccountRecord.self).id
      return try await listSearchPage(remindersData(context), args: args, accountID: id)
    })
  accountFields["reminders"] = GraphQLField(
    type: reminderPage,
    description: "Reminders in this account, including completed items; filters apply within it.",
    args: reminderArgs,
    resolve: { source, args, context, _ in
      let id = try record(source, as: AccountRecord.self).id
      let data = try await remindersData(context)
      return try await searchPage(
        data, args: args, context: context,
        scope: Set(data.lists.filter { $0.source.id == id }.map(\.id)))
    })
  account.fields = { accountFields }
  var listFields = try list.fields()
  listFields["container"] = containerField(
    listContainer,
    reference: { (context, list: ListRecord) in
      try await context.container(listID: list.id)
    },
    description:
      "The account or parent list containing this list. \(automationNote)"
  )
  listFields["account"] = GraphQLField(
    type: account, description: "The account that owns the list.",
    resolve: { source, _, context, _ in
      let id = try record(source, as: ListRecord.self).source.id
      return try await remindersData(context).accounts.first { $0.id == id }
    })
  listFields["reminders"] = GraphQLField(
    type: reminderPage,
    description: "Reminders in this list, including completed items; filters apply within it.",
    args: reminderArgs,
    resolve: { source, args, context, _ in
      let id = try record(source, as: ListRecord.self).id
      return try await searchPage(remindersData(context), args: args, context: context, scope: [id])
    })
  listFields["summary"] = GraphQLField(
    type: summary, description: "Reminder counts for the whole list, regardless of pagination.",
    resolve: { source, _, context, _ in
      let id = try record(source, as: ListRecord.self).id
      return try await summarize(remindersData(context), listId: id)
    })
  list.fields = { listFields }
  var reminderFields = try reminder.fields()
  reminderFields["container"] = containerField(
    reminderContainer,
    reference: { (context, item: ReminderRecord) in
      try await context.container(reminderID: item.id)
    },
    description:
      "The list or parent reminder containing this reminder. \(automationNote)"
  )
  reminderFields["list"] = GraphQLField(
    type: list, description: "The owning list.",
    resolve: { source, _, context, _ in
      guard let id = try record(source, as: ReminderRecord.self).listId else { return nil }
      return try await remindersData(context).lists.first { $0.id == id }
    })
  reminder.fields = { reminderFields }
  let mutation = try makeMutationType(
    reminder: reminder, list: list, dateTime: dateTime, localDate: localDate, proximity: proximity,
    frequency: frequency, weekday: weekday)
  return try GraphQLSchema(
    query: GraphQLObjectType(
      name: "Query",
      fields: [
        "accounts": GraphQLField(
          type: GraphQLList(GraphQLNonNull(account)),
          description: "Accounts available in Reminders.",
          resolve: { _, _, context, _ in try await remindersData(context).accounts }),
        "account": GraphQLField(
          type: account,
          description: "Find an account by its unique identifier; null when missing.", args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await remindersData(context).accounts.first { $0.id == id }
          }),
        "lists": GraphQLField(
          type: listPage, description: "Lists available in Reminders.", args: listArgs,
          resolve: { _, args, context, _ in
            try await listSearchPage(remindersData(context), args: args)
          }),
        "list": GraphQLField(
          type: list, description: "Find a list by its unique identifier; null when missing.",
          args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await remindersData(context).lists.first { $0.id == id }
          }),
        "reminders": GraphQLField(
          type: reminderPage,
          description: "Reminders available in the application, including completed items.",
          args: reminderArgs,
          resolve: { _, args, context, _ in
            try await searchPage(remindersData(context), args: args, context: context)
          }),
        "reminder": GraphQLField(
          type: reminder,
          description: "Find a reminder by its unique identifier; null when missing.", args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await remindersData(context).reminders.first { $0.id == id }
          }),
        "defaultAccount": GraphQLField(
          type: account,
          description: "The default account in Reminders, or null if none is available.",
          resolve: { _, _, context, _ in
            try await remindersData(context).defaultAccount
          }
        ),
        "defaultList": GraphQLField(
          type: list, description: "The default reminder list, or null if none is available.",
          resolve: { _, _, context, _ in
            try await remindersData(context).defaultList
          }),
      ]), mutation: mutation)
}
