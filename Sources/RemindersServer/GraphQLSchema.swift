import Foundation
import GraphQL

func mapValue(_ value: Map) -> (any Sendable)? {
  switch value {
  case .null, .undefined: return nil
  case .array(let values): return values
  default: return value
  }
}
func field(_ type: GraphQLOutputType, key: String? = nil, description: String? = nil)
  -> GraphQLField
{
  GraphQLField(
    type: type, description: description,
    resolve: { source, _, _, info in
      guard let source = source as? Map else { return nil }
      return mapValue(source[key ?? info.fieldName])
    })
}
func graphMap<T: Encodable>(_ value: T) throws -> Map {
  try JSONDecoder().decode(Map.self, from: JSONEncoder().encode(value))
}
func graphMaps<T: Encodable>(_ values: [T]) throws -> [Map] { try values.map(graphMap) }
private func remindersData(_ context: (any Sendable)?) async throws -> RemindersData {
  guard let context = context as? GraphQLContext else {
    throw ServerError.internalError("Missing reminders data resolver context")
  }
  return try await context.remindersData()
}
private func searchPage(
  _ data: RemindersData, args: Map, context: (any Sendable)?, scope: Set<String>? = nil
) async throws -> Map {
  let criteria = args["filter"]
  var search = Search()
  search.query = try? criteria["query"].stringValue()
  search.nameContains = try? criteria["nameContains"].stringValue()
  search.accountIds = try? criteria["accountIds"].arrayValue().map { try $0.stringValue() }
  search.listIds = try? criteria["listIds"].arrayValue().map { try $0.stringValue() }
  search.hasDueDate = try? criteria["hasDueDate"].boolValue()
  search.completed = try? criteria["completed"].boolValue()
  search.flagged = try? criteria["flagged"].boolValue()
  search.priorities = try? criteria["priorities"].arrayValue().map { try $0.intValue() }
  guard search.priorities?.allSatisfy({ (0...9).contains($0) }) ?? true else {
    throw ServerError.invalidArgument("priorities must be 0...9")
  }
  search.dueStatus = (try? criteria["dueStatus"].stringValue()).flatMap(DueStatus.init(rawValue:))
  search.dueOnOrAfter = try? criteria["dueOnOrAfter"].stringValue()
  search.dueBefore = try? criteria["dueBefore"].stringValue()
  search.dueFrom = try? criteria["dueFrom"].stringValue()
  if args["orderBy"] != .null && args["orderBy"] != .undefined {
    search.orderField = try args["orderBy"]["field"].stringValue()
    search.descending = (try? args["orderBy"]["direction"].stringValue()) == "DESC"
  }
  var flags: [String: Bool]?
  if search.flagged != nil {
    guard let context = context as? GraphQLContext else {
      throw ServerError.internalError("Missing flag context")
    }
    flags = try await context.flags()
  }
  return try page(search.reminders(data, scope: scope, flags: flags), args: args)
}
func page<T: Encodable>(_ values: [T], args: Map) throws -> Map {
  let limit = try args["limit"].intValue()
  let offset = try args["offset"].intValue()
  guard (1...100).contains(limit), offset >= 0 else {
    throw ServerError.invalidArgument("limit must be 1...100 and offset must be nonnegative")
  }
  let start = min(offset, values.count)
  let end = min(start + limit, values.count)
  return [
    "items": Map(try graphMaps(Array(values[start..<end]))), "totalCount": Map(values.count),
    "pageInfo": [
      "offset": Map(offset), "limit": Map(limit), "hasNextPage": Map(end < values.count),
      "hasPreviousPage": Map(offset > 0 && !values.isEmpty),
    ],
  ]
}

// One cache per HTTP execution, shared by item fields and root aliases. A Task
// caches failures as well as successes and coalesces concurrent resolver calls.
actor GraphQLContext {
  func invalidate() {
    data = nil
    lookup = nil
    properties.removeAll()
  }
  private var properties: [String: Task<[String: Map], Error>] = [:]
  func property<Value: Encodable>(_ property: ScriptProperty<Value>, id: String) async throws -> Map
  {
    let command = property.expression
    if properties[command] == nil {
      properties[command] = Task { try await readProperty(property).mapValues { try graphMap($0) } }
    }
    let values = try await properties[command]!.value
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

// Shared by the recurrence output types and their mutation inputs.
let recurrenceDescriptions = [
  "frequency": "The unit of repetition.",
  "interval": "Positive number of frequency units between occurrences.",
  "daysOfWeek": "Weekday constraints. Null means unconstrained. Not allowed for daily rules.",
  "daysOfMonth":
    "Days 1..31 or -31..-1 counting backward from the end of the month. Monthly rules only.",
  "monthsOfYear": "Months 1..12. Yearly rules only.",
  "weeksOfYear":
    "Week numbers 1..53 or -53..-1 counting backward from year end. Yearly rules only.",
  "daysOfYear": "Year days 1..366 or -366..-1 counting backward from year end. Yearly rules only.",
  "setPositions":
    "Select positions 1..366 or -366..-1 from occurrences matching the other constraints in each period. Requires another selector.",
  "end": "When repetition stops; null means no specified end.",
  "day": "The weekday to match.",
  "ordinal":
    "Occurrence of this weekday: 1 is first, -1 last; omit for every occurrence. Valid range -53..53 excluding zero; non-null ordinals require monthly or yearly frequency.",
  "count": "Positive number of occurrences; mutually exclusive with until.",
  "until": "Inclusive end timestamp; mutually exclusive with count.",
]
let automationNote = "Read through Reminders automation, which may need Automation permission."
// Shared by the Geofence output type and GeofenceInput.
let geofenceDescriptions = [
  "title": "Optional display name of the location.",
  "latitude": "Latitude in degrees, between -90 and 90.",
  "longitude": "Longitude in degrees, between -180 and 180.",
  "radiusMeters":
    "Radius in meters. Zero requests the system default; positive values request a minimum radius.",
  "proximity": "Whether entering or leaving the region triggers the alert.",
]

// Field descriptions by type name; the MCP catalog reuses them for matching fields.
func graphQLFieldDescriptions() throws -> [String: [String: String]] {
  var result: [String: [String: String]] = [:]
  for (name, type) in try makeSchema().typeMap {
    var fields: [String: String] = [:]
    if let type = type as? GraphQLObjectType {
      for (key, field) in try type.fields() { fields[key] = field.description }
    } else if let type = type as? GraphQLInputObjectType {
      for (key, field) in try type.fields() { fields[key] = field.description }
    }
    if !fields.isEmpty { result[name] = fields }
  }
  return result
}

func makeSchema() throws -> GraphQLSchema {
  let account = try GraphQLObjectType(
    name: "Account",
    fields: [
      "id": field(
        GraphQLNonNull(GraphQLID),
        description: "Unique identifier of the account. Treat this value as opaque."),
      "name": field(GraphQLString, description: "The name of the account."),
    ])
  let list = try GraphQLObjectType(
    name: "ReminderList",
    fields: [
      "id": field(
        GraphQLNonNull(GraphQLID),
        description: "Unique identifier of the list. Treat this value as opaque."),
      "name": field(GraphQLString, description: "The name of the list."),
      "allowsContentModifications": field(
        GraphQLBoolean,
        description: "Whether reminders can be added, edited, and deleted in this list."),
      "allowsListModifications": field(
        GraphQLBoolean,
        description: "Whether the list's own properties can be edited and the list deleted."),
      "subscribed": field(GraphQLBoolean, description: "Whether the list is a subscription."),
      "color": field(
        GraphQLString,
        description: "The color of the list as an sRGB #RRGGBBAA hex string."),
      "emblem": GraphQLField(
        type: GraphQLString,
        description:
          "The emblem icon name displayed beside the list. \(automationNote)",
        resolve: { source, _, context, _ in
          guard let source = source as? Map, let context = context as? GraphQLContext else {
            return nil
          }
          return try await mapValue(
            context.property(.emblems, id: source["id"].stringValue()))
        }),
    ])
  let dateTime = try GraphQLScalarType(
    name: "DateTime", description: "RFC 3339 timestamp with an explicit offset, serialized in UTC.",
    // Every output date comes from timestamp() and is already canonical UTC.
    serialize: { value in Map(try (value as? Map ?? Map(any: value)).stringValue()) },
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
    fields: GraphQLFieldMap(
      uniqueKeysWithValues: [
        "era", "year", "month", "day", "hour", "minute", "second", "nanosecond", "weekday",
        "weekdayOrdinal", "quarter", "weekOfMonth", "weekOfYear", "yearForWeekOfYear",
      ].map { ($0, field(GraphQLInt)) } + [
        ("calendar", field(GraphQLString)), ("timeZone", field(GraphQLString)),
        ("isLeapMonth", field(GraphQLBoolean)),
      ]))
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
    "DueStatus", DueStatus.allCases.map(\.rawValue),
    descriptions: [
      "OVERDUE": "A timed deadline has passed, or an all-day deadline is before today.",
      "TODAY": "The deadline falls today and has not passed.",
      "FUTURE": "The deadline falls after today.", "UNSCHEDULED": "No due date.",
      "UNKNOWN": "The due date cannot be classified.",
    ])
  let direction = try enumeration(
    "SortDirection", ["ASC", "DESC"],
    descriptions: ["ASC": "Smallest or earliest first.", "DESC": "Largest or latest first."])
  let orderField = try enumeration(
    "ReminderSortField", reminderSortFields,
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
        type: GraphQLNonNull(orderField), description: "Property to sort by."),
      "direction": InputObjectField(
        type: direction, defaultValue: "ASC",
        description:
          "Direction of ordering. Nulls sort last either way and ties use identifier order; without orderBy, reminders use identifier order."
      ),
    ])
  let listOrder = try GraphQLInputObjectType(
    name: "ListOrder",
    fields: [
      "direction": InputObjectField(
        type: direction, defaultValue: "ASC",
        description:
          "Direction of name ordering. Ties use identifier order; without orderBy, lists use identifier order."
      )
    ])
  let listFilter = try GraphQLInputObjectType(
    name: "ListFilter",
    fields: [
      "query": InputObjectField(
        type: GraphQLString, description: "Case-insensitive substring of the list name."),
      "accountIds": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLID)),
        description:
          "Match lists in any of these accounts, intersected with the parent scope; [] matches nothing."
      ),
      "allowsContentModifications": InputObjectField(
        type: GraphQLBoolean, description: "Match whether reminders in the list can be modified."),
      "subscribed": InputObjectField(
        type: GraphQLBoolean, description: "Match subscribed or unsubscribed lists."),
    ])
  let structuredLocation = try GraphQLObjectType(
    name: "StructuredLocation",
    fields: [
      "title": field(GraphQLString, description: "Display name of the location."),
      "latitude": field(GraphQLFloat, description: "Latitude in degrees, when set."),
      "longitude": field(GraphQLFloat, description: "Longitude in degrees, when set."),
      "radius": field(
        GraphQLNonNull(GraphQLFloat),
        description: "Radius in meters; zero means the system default."
      ),
    ])
  let alarm = try GraphQLObjectType(
    name: "RawAlarm",
    description: "An alarm exactly as stored.",
    fields: [
      "absoluteDate": field(dateTime, description: "Absolute trigger time, when set."),
      "relativeOffset": field(
        GraphQLNonNull(GraphQLFloat),
        description:
          "Seconds from the start date. Zero alone does not distinguish absolute and relative triggers."
      ),
      "proximity": field(
        GraphQLNonNull(GraphQLString), description: "none, enter, leave, or unknown."),
      "structuredLocation": field(
        structuredLocation, description: "The location of a geofence trigger, when set."),
    ])
  let proximity = try enumeration(
    "GeofenceProximity", ["ARRIVE", "DEPART"],
    descriptions: [
      "ARRIVE": "Trigger when entering the region.", "DEPART": "Trigger when leaving the region.",
    ])
  let geofence = try GraphQLObjectType(
    name: "Geofence",
    fields: [
      "title": field(GraphQLString, description: geofenceDescriptions["title"]),
      "latitude": field(
        GraphQLNonNull(GraphQLFloat), description: geofenceDescriptions["latitude"]),
      "longitude": field(
        GraphQLNonNull(GraphQLFloat), description: geofenceDescriptions["longitude"]),
      "radiusMeters": field(
        GraphQLNonNull(GraphQLFloat), description: geofenceDescriptions["radiusMeters"]),
      "proximity": field(
        GraphQLNonNull(proximity), description: geofenceDescriptions["proximity"]),
    ])
  let absoluteAlarm = try GraphQLObjectType(
    name: "AbsoluteAlarm",
    fields: [
      "at": field(
        GraphQLNonNull(dateTime), description: "The date and time at which the alert triggers.")
    ])
  let relativeAlarm = try GraphQLObjectType(
    name: "RelativeAlarm",
    fields: [
      "offsetSeconds": field(
        GraphQLNonNull(GraphQLFloat),
        description: "Seconds from the start date: negative before, zero at, positive after.")
    ])
  let locationAlarm = try GraphQLObjectType(
    name: "LocationAlarm",
    fields: [
      "geofence": field(
        GraphQLNonNull(geofence), description: "Region and direction that trigger the alert.")
    ])
  let resolveTypename: GraphQLTypeResolve = { value, _ in
    guard let value = value as? Map else { throw ServerError.internalError("Invalid union member") }
    return try value["__typename"].stringValue()
  }
  let alarmUnion = try GraphQLUnionType(
    name: "ReminderAlarm", resolveType: resolveTypename,
    types: [absoluteAlarm, relativeAlarm, locationAlarm])
  let recurrenceDay = try GraphQLObjectType(
    name: "RecurrenceDay",
    fields: [
      "dayOfTheWeek": field(GraphQLNonNull(GraphQLInt), description: "Weekday, Sunday = 1."),
      "weekNumber": field(
        GraphQLNonNull(GraphQLInt), description: "Signed ordinal; zero means every occurrence."),
    ])
  let recurrenceEnd = try GraphQLObjectType(
    name: "RecurrenceEnd",
    fields: [
      "endDate": field(dateTime, description: "End timestamp, when set."),
      "occurrenceCount": field(
        GraphQLNonNull(GraphQLInt), description: "Number of occurrences; zero when unset."),
    ])
  var recurrenceFields: GraphQLFieldMap = [
    "frequency": field(
      GraphQLNonNull(GraphQLString), description: "daily, weekly, monthly, yearly, or unknown."),
    "calendarIdentifier": field(
      GraphQLNonNull(GraphQLString), description: "Calendar the rule is evaluated in."),
    "interval": field(
      GraphQLNonNull(GraphQLInt), description: "Frequency units between occurrences."),
    "firstDayOfTheWeek": field(
      GraphQLNonNull(GraphQLInt), description: "First day of the week, Sunday = 1; zero is unset."),
    "daysOfTheWeek": field(
      GraphQLNonNull(GraphQLList(GraphQLNonNull(recurrenceDay))),
      description: "Weekday constraints; empty when unconstrained."),
    "end": field(recurrenceEnd, description: "When repetition stops; null for no end."),
  ]
  for name in [
    "daysOfTheMonth", "daysOfTheYear", "weeksOfTheYear", "monthsOfTheYear", "setPositions",
  ] {
    recurrenceFields[name] = field(
      GraphQLNonNull(GraphQLList(GraphQLNonNull(GraphQLInt))),
      description: "Selector values; empty when unconstrained.")
  }
  let recurrence = try GraphQLObjectType(
    name: "RecurrenceRule", description: "A recurrence rule exactly as stored.",
    fields: recurrenceFields)
  let frequency = try enumeration(
    "RecurrenceFrequency", ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"],
    descriptions: [
      "DAILY": "Repeat in day intervals.", "WEEKLY": "Repeat in week intervals.",
      "MONTHLY": "Repeat in month intervals.", "YEARLY": "Repeat in year intervals.",
    ])
  let weekday = try enumeration(
    "Weekday", weekdayNames,
    descriptions: Dictionary(uniqueKeysWithValues: weekdayNames.map { ($0, $0.capitalized + ".") }))
  let scheduleDay = try GraphQLObjectType(
    name: "ReminderRecurrenceDay",
    fields: [
      "day": field(GraphQLNonNull(weekday), description: recurrenceDescriptions["day"]),
      "ordinal": field(GraphQLInt, description: recurrenceDescriptions["ordinal"]),
    ])
  let scheduleEnd = try GraphQLObjectType(
    name: "ReminderRecurrenceEnd",
    fields: [
      "until": field(dateTime, description: recurrenceDescriptions["until"]),
      "count": field(GraphQLInt, description: recurrenceDescriptions["count"]),
    ])
  var scheduleFields: GraphQLFieldMap = [
    "frequency": field(
      GraphQLNonNull(frequency), description: recurrenceDescriptions["frequency"]),
    "interval": field(GraphQLNonNull(GraphQLInt), description: recurrenceDescriptions["interval"]),
    "daysOfWeek": field(
      GraphQLList(GraphQLNonNull(scheduleDay)), description: recurrenceDescriptions["daysOfWeek"]),
    "end": field(scheduleEnd, description: recurrenceDescriptions["end"]),
  ]
  for name in ["daysOfMonth", "monthsOfYear", "weeksOfYear", "daysOfYear", "setPositions"] {
    scheduleFields[name] = field(
      GraphQLList(GraphQLNonNull(GraphQLInt)), description: recurrenceDescriptions[name])
  }
  let schedule = try GraphQLObjectType(name: "ReminderRecurrence", fields: scheduleFields)
  let filter = try GraphQLInputObjectType(
    name: "ReminderFilter",
    fields: [
      "query": InputObjectField(
        type: GraphQLString, description: "Match text in the reminder name or notes."),
      "accountIds": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLID)),
        description: "Match reminders belonging to these accounts; [] matches nothing."),
      "flagged": InputObjectField(
        type: GraphQLBoolean,
        description:
          "Match flagged or unflagged reminders. Uses Reminders automation; a failed read fails the collection."
      ),
      "hasDueDate": InputObjectField(
        type: GraphQLBoolean,
        description: "Match reminders with or without a timed or all-day deadline."),
      "dueFrom": InputObjectField(
        type: dateTime, description: "Inclusive lower bound on the deadline."),
      "listIds": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLID)),
        description: "Match reminders belonging to these lists; [] matches nothing."),
      "priorities": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLInt)),
        description: "Match any of these exact numeric priorities; [] matches nothing."),
      "dueStatus": InputObjectField(
        type: dueStatus, description: "Match a deadline status, independent of completion."),
      "dueOnOrAfter": InputObjectField(
        type: GraphQLString,
        description:
          "Inclusive lower deadline bound as YYYY-MM-DD, using the host zone for timed deadlines. Do not mix timestamp and calendar-day bounds."
      ),
      "dueBefore": InputObjectField(
        type: GraphQLString,
        description:
          "Exclusive upper deadline bound: timestamp or YYYY-MM-DD. Do not mix timestamp and calendar-day bounds."
      ),
      "completed": InputObjectField(
        type: GraphQLBoolean,
        description: "Match completed or incomplete reminders; omission includes both."),
      "nameContains": InputObjectField(
        type: GraphQLString, description: "Case-insensitive substring of the reminder name."),
    ])
  let reminder = try GraphQLObjectType(
    name: "Reminder",
    fields: [
      "id": field(
        GraphQLNonNull(GraphQLID),
        description: "Unique identifier of the reminder. Treat this value as opaque."),
      "name": field(GraphQLString, description: "The name of the reminder."),
      "body": field(GraphQLString, description: "The notes attached to the reminder."),
      "completed": field(GraphQLBoolean, description: "Whether the reminder is marked completed."),
      "priority": field(
        GraphQLInt,
        description: "The priority of the reminder: 0 none, 1–4 high, 5 medium, or 6–9 low."),
      "creationDate": field(dateTime, description: "The date and time the reminder was created."),
      "completionDate": field(
        dateTime, description: "The date and time the reminder was completed."),
      "modificationDate": field(
        dateTime, description: "The date and time the reminder was last modified."),
      "location": field(
        GraphQLString,
        description: "Descriptive location text, separate from location-triggered alarms."),
      "dueDay": field(
        GraphQLString,
        description:
          "The deadline's calendar day: timed deadlines in the host zone, all-day deadlines as stored. Null when undated or unclassifiable."
      ),
      "listId": field(GraphQLID, description: "Identifier of the owning list."),
      "url": field(
        url,
        description:
          "An associated absolute URL; does not promise a rich-link preview in Reminders."),
      "startDateComponents": field(components, description: "The stored start date components."),
      "dueDateComponents": field(components, description: "The stored due date components."),
      "dueStatus": field(
        GraphQLNonNull(dueStatus), description: "Deadline status, independent of completion."),
      "rawAlarms": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(alarm))), key: "alarms",
        description:
          "Alarms exactly as stored, including triggers the alarms union cannot represent."
      ),
      "alarms": GraphQLField(
        type: GraphQLList(GraphQLNonNull(alarmUnion)),
        description:
          "Configured alerts. An empty list means no alerts; null indicates a read failure or a trigger this union cannot represent, and rawAlarms holds the stored values.",
        resolve: { source, _, _, _ in
          guard let source = source as? Map else { return nil }
          return try alarmProjections(source)
        }),
      "recurrenceRules": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(recurrence))),
        description: "Recurrence rules exactly as stored; empty when none."),
      "recurrence": GraphQLField(
        type: schedule,
        description:
          "A single repeating schedule; null when no recurrence is configured. Multiple rules produce a field error, and recurrenceRules holds the stored rules.",
        resolve: { source, _, _, _ in
          guard let source = source as? Map else { return nil }
          return try recurrenceProjection(source)
        }),
      "flagged": GraphQLField(
        type: GraphQLBoolean,
        description:
          "Whether the reminder is flagged. This is independent of its priority. \(automationNote)",
        resolve: { source, _, context, _ in
          guard let item = source as? Map, let context = context as? GraphQLContext else {
            throw ServerError.internalError("Missing reminder resolver context")
          }
          return try await context.flag(id: item["id"].stringValue())
        }),
      "remindMeDate": GraphQLField(
        type: dateTime,
        description:
          "The date and time at which to remind the user. \(automationNote)",
        resolve: { source, _, context, _ in
          guard let source = source as? Map, let context = context as? GraphQLContext else {
            return nil
          }
          return try await mapValue(
            context.property(.alerts, id: source["id"].stringValue()))
        }),
      "dueDate": calendarField(
        dateTime, key: "dueDateComponents", timed: true,
        description:
          "The date and time by which the reminder is due. Unsupported components produce a field error; dueDateComponents holds the stored value."
      ),
      "startDate": calendarField(
        dateTime, key: "startDateComponents", timed: true,
        description:
          "The date and time at which work on the reminder starts. Unsupported components produce a field error; startDateComponents holds the stored value."
      ),
      "allDayDueDate": calendarField(
        localDate, key: "dueDateComponents", timed: false,
        description: "The calendar date on which the reminder is due, without a time of day."),
      "allDayStartDate": calendarField(
        localDate, key: "startDateComponents", timed: false,
        description: "A date-only start, without a time of day."),
      "timeZone": GraphQLField(
        type: GraphQLString,
        description:
          "IANA time-zone identifier, or null for floating/local date interpretation. Different start and due zones produce a field error.",
        resolve: { source, _, _, _ in
          guard let source = source as? Map else { return nil }
          let due = try componentValue(source, key: "dueDateComponents")
          let start = try componentValue(source, key: "startDateComponents")
          if let due, let start, due.timeZone != start.timeZone {
            throw ServerError.unsupported(
              "start and due dates use different time zones; inspect component fields")
          }
          return due?.timeZone ?? start?.timeZone
        }),
    ])
  let pageInfo = try GraphQLObjectType(
    name: "PageInfo",
    fields: [
      "offset": field(GraphQLNonNull(GraphQLInt), description: "Requested zero-based offset."),
      "limit": field(GraphQLNonNull(GraphQLInt), description: "Requested maximum page size."),
      "hasNextPage": field(
        GraphQLNonNull(GraphQLBoolean), description: "Whether results exist after this page."),
      "hasPreviousPage": field(
        GraphQLNonNull(GraphQLBoolean),
        description: "Whether matching results exist before the requested offset."),
    ])
  func pageType(_ name: String, _ item: GraphQLObjectType, noun: String) throws
    -> GraphQLObjectType
  {
    try GraphQLObjectType(
      name: name,
      fields: [
        "items": field(
          GraphQLNonNull(GraphQLList(GraphQLNonNull(item))),
          description: "\(noun.capitalized) in this page."),
        "totalCount": field(
          GraphQLNonNull(GraphQLInt), description: "Number of matching \(noun) before pagination."),
        "pageInfo": field(
          GraphQLNonNull(pageInfo), description: "Position and availability of neighboring pages."),
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
  let listPage = try pageType("ListPage", list, noun: "lists")
  let reminderPage = try pageType("ReminderPage", reminder, noun: "reminders")
  let summary = try GraphQLObjectType(
    name: "ListSummary",
    fields: GraphQLFieldMap(
      uniqueKeysWithValues: [
        ("total", "All reminders in the list, including completed ones."),
        ("completed", "Completed reminders."), ("incomplete", "Incomplete reminders."),
        ("overdue", "Incomplete reminders whose deadline has passed."),
        ("scheduled", "Reminders with a due date, including completed ones."),
        ("recurring", "Reminders with recurrence rules, including completed ones."),
        ("withAlarms", "Reminders with alarms, including completed ones."),
      ].map { ($0.0, field(GraphQLNonNull(GraphQLInt), description: $0.1)) }))
  let listContainer = try GraphQLUnionType(
    name: "ListContainer", resolveType: resolveTypename, types: [account, list])
  let reminderContainer = try GraphQLUnionType(
    name: "ReminderContainer", resolveType: resolveTypename, types: [list, reminder])
  func containerField(
    _ type: GraphQLUnionType, property: ScriptProperty<ContainerReference>, description: String
  ) -> GraphQLField {
    GraphQLField(
      type: type, description: description,
      resolve: { source, _, context, _ in
        guard let source = source as? Map, let context = context as? GraphQLContext else {
          return nil
        }
        let reference = try await context.property(property, id: source["id"].stringValue())
        let id = try reference["id"].stringValue()
        let kind = try reference["kind"].stringValue()
        let data = try await context.remindersData()
        var value: Map?
        switch kind {
        case "Account":
          value = try data.accounts.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }.map(
            graphMap)
        case "ReminderList":
          value = try data.lists.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }.map(
            graphMap)
        case "Reminder":
          value = try data.reminders.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }.map(
            graphMap)
        default: break
        }
        guard var result = value else {
          throw ServerError.internalError(
            "Container is outside the accessible reminders or changed during the read")
        }
        result["__typename"] = Map(kind)
        return result
      })
  }
  var accountFields = try account.fields()
  accountFields["lists"] = GraphQLField(
    type: listPage, description: "Lists in this account; filters apply within it.", args: listArgs,
    resolve: { source, args, context, _ in
      guard let source = source as? Map else { return nil }
      let id = try source["id"].stringValue()
      return try await listSearchPage(remindersData(context), args: args, accountID: id)
    })
  accountFields["reminders"] = GraphQLField(
    type: reminderPage,
    description: "Reminders in this account, including completed items; filters apply within it.",
    args: reminderArgs,
    resolve: { source, args, context, _ in
      guard let source = source as? Map else { return nil }
      let id = try source["id"].stringValue()
      let data = try await remindersData(context)
      return try await searchPage(
        data, args: args, context: context,
        scope: Set(data.lists.filter { $0.source.id == id }.map(\.id)))
    })
  account.fields = { accountFields }
  var listFields = try list.fields()
  listFields["container"] = containerField(
    listContainer, property: .listContainers,
    description:
      "The account or parent list containing this list. \(automationNote)"
  )
  listFields["account"] = GraphQLField(
    type: account, description: "The account that owns the list.",
    resolve: { source, _, context, _ in
      guard let source = source as? Map else { return nil }
      let id = try source["source"]["id"].stringValue()
      return try await remindersData(context).accounts.first { $0.id == id }.map(graphMap)
    })
  listFields["reminders"] = GraphQLField(
    type: reminderPage,
    description: "Reminders in this list, including completed items; filters apply within it.",
    args: reminderArgs,
    resolve: { source, args, context, _ in
      guard let source = source as? Map else { return nil }
      return try await searchPage(
        remindersData(context), args: args, context: context, scope: [source["id"].stringValue()])
    })
  listFields["summary"] = GraphQLField(
    type: summary, description: "Reminder counts for the whole list, regardless of pagination.",
    resolve: { source, _, context, _ in
      guard let source = source as? Map else { return nil }
      return try await graphMap(
        summarize(remindersData(context), listId: source["id"].stringValue()))
    })
  list.fields = { listFields }
  var reminderFields = try reminder.fields()
  reminderFields["container"] = containerField(
    reminderContainer, property: .reminderContainers,
    description:
      "The list or parent reminder containing this reminder. \(automationNote)"
  )
  reminderFields["list"] = GraphQLField(
    type: list, description: "The owning list.",
    resolve: { source, _, context, _ in
      guard let source = source as? Map, let id = try? source["listId"].stringValue() else {
        return nil
      }
      return try await remindersData(context).lists.first { $0.id == id }.map(graphMap)
    })
  reminder.fields = { reminderFields }
  let mutation = try makeMutationType(
    reminder: reminder, list: list, dateTime: dateTime, localDate: localDate, proximity: proximity,
    frequency: frequency, weekday: weekday
  ) { context in
    await (context as? GraphQLContext)?.invalidate()
  }
  return try GraphQLSchema(
    query: GraphQLObjectType(
      name: "Query",
      fields: [
        "accounts": GraphQLField(
          type: GraphQLList(GraphQLNonNull(account)),
          description: "Accounts available in Reminders.",
          resolve: { _, _, context, _ in try await graphMaps(remindersData(context).accounts) }),
        "account": GraphQLField(
          type: account,
          description: "Find an account by its unique identifier; null when missing.", args: idArg,
          resolve: { _, args, context, _ in
            let id = try args["id"].stringValue()
            return try await remindersData(context).accounts.first { $0.id == id }.map(graphMap)
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
            let id = try args["id"].stringValue()
            return try await remindersData(context).lists.first { $0.id == id }.map(graphMap)
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
            let id = try args["id"].stringValue()
            return try await remindersData(context).reminders.first { $0.id == id }.map(graphMap)
          }),
        "defaultAccount": GraphQLField(
          type: account,
          description: "The default account in Reminders, or null if none is available.",
          resolve: { _, _, context, _ in
            try await remindersData(context).defaultAccount.map(graphMap)
          }
        ),
        "defaultList": GraphQLField(
          type: list, description: "The default reminder list, or null if none is available.",
          resolve: { _, _, context, _ in try await remindersData(context).defaultList.map(graphMap)
          }),
      ]), mutation: mutation)
}
