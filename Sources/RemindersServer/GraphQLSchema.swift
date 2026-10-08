import Foundation
import GraphQL

func mapValue(_ value: Map) -> (any Sendable)? {
  switch value {
  case .null, .undefined: return nil
  case .array(let values): return values
  default: return value
  }
}
func field(_ type: GraphQLOutputType, key: String? = nil) -> GraphQLField {
  GraphQLField(
    type: type,
    resolve: { source, _, _, info in
      guard let source = source as? Map else { return nil }
      return mapValue(source[key ?? info.fieldName])
    })
}
func graphMap<T: Encodable>(_ value: T) throws -> Map {
  try JSONDecoder().decode(Map.self, from: JSONEncoder().encode(value))
}
func graphMaps<T: Encodable>(_ values: [T]) throws -> [Map] { try values.map(graphMap) }
private func inventory(_ context: (any Sendable)?) async throws -> Inventory {
  guard let context = context as? GraphQLContext else {
    throw ServerError.message("Missing inventory resolver context")
  }
  return try await context.inventory()
}
private func searchPage(
  _ data: Inventory, args: Map, context: (any Sendable)?, scope: Set<String>? = nil
) async throws -> Map {
  let criteria = args["filter"]
  let text = try? criteria["query"].stringValue().lowercased()
  let accounts = try? criteria["accountIds"].arrayValue().map { try $0.stringValue() }
  let accountLists = accounts.map { accounts in
    Set(data.lists.filter { accounts.contains($0.source.id) }.map(\.id))
  }
  let hasDueDate = try? criteria["hasDueDate"].boolValue()
  let flagged = try? criteria["flagged"].boolValue()
  var flags: [String: Bool]?
  if flagged != nil {
    guard let context = context as? GraphQLContext else {
      throw ServerError.message("Missing flag context")
    }
    flags = try await context.flags()
  }
  let ids = try? criteria["listIds"].arrayValue().map { try $0.stringValue() }
  let completed = try? criteria["completed"].boolValue()
  let query = try? criteria["nameContains"].stringValue()
  let priorities = try? criteria["priorities"].arrayValue().map { try $0.intValue() }
  guard priorities?.allSatisfy({ (0...9).contains($0) }) ?? true else {
    throw ServerError.message("priorities must be 0...9")
  }
  let status = try? criteria["dueStatus"].stringValue().lowercased()
  let lower = try? criteria["dueOnOrAfter"].stringValue()
  let upper = try? criteria["dueBefore"].stringValue()
  let from = try? criteria["dueFrom"].stringValue()
  let timestampUpper = upper.flatMap { $0.contains("T") ? $0 : nil }
  let dayUpper = upper.flatMap { $0.contains("T") ? nil : $0 }
  guard !(from != nil && (lower != nil || dayUpper != nil)),
    !(lower != nil && timestampUpper != nil)
  else {
    throw ServerError.message("INVALID_ARGUMENT: do not mix calendar-day and timestamp bounds")
  }
  try validateDays(lower, dayUpper)
  let fromDate = try from.map(parseTimestamp)
  let beforeDate = try timestampUpper.map(parseTimestamp)
  if let fromDate, let beforeDate, fromDate >= beforeDate {
    throw ServerError.message("INVALID_ARGUMENT: dueFrom must precede dueBefore")
  }
  let items = try data.reminders.filter { item in
    if let flags, flags[item.id] == nil {
      throw ServerError.message("Reminder changed during flag filtering; retry")
    }
    if let flagged, flags?[item.id] != flagged { return false }
    if fromDate != nil || beforeDate != nil {
      guard let date = try projectDate(item.dueDateComponents)?.instant,
        fromDate == nil || date >= fromDate!, beforeDate == nil || date < beforeDate!
      else { return false }
    }
    return (accountLists == nil || accountLists!.contains(item.listId ?? ""))
      && (hasDueDate == nil || hasDueDate == (item.dueDateComponents != nil))
      && (text == nil || (item.name ?? "").lowercased().contains(text!)
        || (item.body ?? "").lowercased().contains(text!))
      && (scope == nil || scope!.contains(item.listId ?? ""))
      && (priorities == nil || priorities!.contains(item.priority))
      && (status == nil || status == item.dueStatus.rawValue)
      && (ids == nil || ids!.contains(item.listId ?? ""))
      && (completed == nil || completed == item.completed)
      && (query == nil || query!.isEmpty
        || (item.name ?? "").lowercased().contains(query!.lowercased()))
      && matchesDays(item.dueDay, lower, dayUpper)
  }
  return try page(graphMaps(orderedReminders(items, args: args)), args: args)
}
func page(_ values: [Map], args: Map) throws -> Map {
  let limit = try args["limit"].intValue()
  let offset = try args["offset"].intValue()
  guard (1...100).contains(limit), offset >= 0 else {
    throw ServerError.message("limit must be 1...100 and offset must be nonnegative")
  }
  let start = min(offset, values.count)
  let end = min(start + limit, values.count)
  return [
    "items": Map(Array(values[start..<end])), "totalCount": Map(values.count),
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
    snapshot = nil
    lookup = nil
    properties.removeAll()
  }
  private var properties: [String: Task<[String: Map], Error>] = [:]
  func property(_ command: String, id: String) async throws -> Map {
    if properties[command] == nil {
      properties[command] = Task { try await readRemindersData(command) }
    }
    let values = try await properties[command]!.value
    guard let key = UUID(uuidString: id)?.uuidString, let value = values[key] else {
      throw ServerError.message("No matching automation object; inventory may have changed")
    }
    return value
  }
  private var lookup: Task<[String: Bool], Error>?
  private var snapshot: Task<Inventory, Error>?
  func inventory() async throws -> Inventory {
    if snapshot == nil { snapshot = Task { try await readInventory() } }
    return try await snapshot!.value
  }
  func flags() async throws -> [String: Bool] {
    if lookup == nil {
      lookup = Task {
        let reminders = try await readReminders(includeFlags: true)
        var flags: [String: Bool] = [:]
        for item in reminders {
          guard let value = item.flagged else {
            throw ServerError.message("Incomplete flagged inventory")
          }
          flags[item.id] = value
        }
        return flags
      }
    }
    return try await lookup!.value
  }
  func flag(id: String) async throws -> Bool? {
    let flags = try await flags()
    guard let value = flags[id] else {
      throw ServerError.message("Reminder changed during flagged field resolution; retry")
    }
    return value
  }
}

func makeSchema() throws -> GraphQLSchema {
  let account = try GraphQLObjectType(
    name: "Account", fields: ["id": field(GraphQLNonNull(GraphQLID)), "name": field(GraphQLString)])
  let list = try GraphQLObjectType(
    name: "ReminderList",
    fields: [
      "id": field(GraphQLNonNull(GraphQLID)), "name": field(GraphQLString, key: "name"),
      "allowsContentModifications": field(GraphQLBoolean),
      "allowsListModifications": GraphQLField(
        type: GraphQLBoolean,
        resolve: { source, _, _, _ in
          guard let source = source as? Map else { return nil }
          return try !source["isImmutable"].boolValue()
        }), "subscribed": field(GraphQLBoolean, key: "isSubscribed"),
      "color": field(GraphQLString),
      "emblem": GraphQLField(
        type: GraphQLString, description: "The emblem icon name displayed beside the list.",
        resolve: { source, _, context, _ in
          guard let source = source as? Map, let context = context as? GraphQLContext else {
            return nil
          }
          return try await mapValue(
            context.property("script-emblems", id: source["id"].stringValue()))
        }),
    ])
  let dateTime = try GraphQLScalarType(
    name: "DateTime", description: "RFC 3339 timestamp with an explicit offset, serialized in UTC.",
    serialize: { value in
      let raw = try (value as? Map ?? Map(any: value)).stringValue()
      return Map(timestamp(try parseTimestamp(raw)))
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
  let priority = try GraphQLScalarType(
    name: "ReminderPriority",
    serialize: { value in
      if let value = value as? Map { return value }
      return try Map(any: value)
    })
  let components = try GraphQLObjectType(
    name: "DateComponents",
    fields: GraphQLFieldMap(
      uniqueKeysWithValues: [
        "era", "year", "month", "day", "hour", "minute", "second", "nanosecond", "weekday",
        "weekdayOrdinal", "quarter", "weekOfMonth", "weekOfYear", "yearForWeekOfYear",
      ].map { ($0, field(GraphQLInt)) } + [
        ("calendar", field(GraphQLString)), ("timeZone", field(GraphQLString)),
        ("isLeapMonth", field(GraphQLBoolean)),
      ]))
  func enumeration(_ name: String, _ values: [String]) throws -> GraphQLEnumType {
    try GraphQLEnumType(
      name: name,
      values: GraphQLEnumValueMap(
        uniqueKeysWithValues: values.map {
          ($0.uppercased(), GraphQLEnumValue(value: .string($0.uppercased())))
        }))
  }
  let dueStatus = try enumeration("DueStatus", DueStatus.allCases.map(\.rawValue))
  let sort = try enumeration("ReminderSort", ReminderSort.allCases.map(\.rawValue))
  let direction = try enumeration("SortDirection", ["ASC", "DESC"])
  let orderField = try enumeration(
    "ReminderSortField",
    ["NAME", "DUE_DATE", "PRIORITY", "CREATION_DATE", "MODIFICATION_DATE", "COMPLETION_DATE"])
  let reminderOrder = try GraphQLInputObjectType(
    name: "ReminderOrder",
    fields: [
      "field": InputObjectField(type: GraphQLNonNull(orderField)),
      "direction": InputObjectField(type: direction, defaultValue: "ASC"),
    ])
  let listOrder = try GraphQLInputObjectType(
    name: "ListOrder", fields: ["direction": InputObjectField(type: direction, defaultValue: "ASC")]
  )
  let listFilter = try GraphQLInputObjectType(
    name: "ListFilter",
    fields: [
      "query": InputObjectField(type: GraphQLString),
      "accountIds": InputObjectField(type: GraphQLList(GraphQLNonNull(GraphQLID))),
      "allowsContentModifications": InputObjectField(type: GraphQLBoolean),
      "subscribed": InputObjectField(type: GraphQLBoolean),
    ])
  let structuredLocation = try GraphQLObjectType(
    name: "StructuredLocation",
    fields: [
      "title": field(GraphQLString), "latitude": field(GraphQLFloat),
      "longitude": field(GraphQLFloat), "radius": field(GraphQLNonNull(GraphQLFloat)),
    ])
  let alarm = try GraphQLObjectType(
    name: "EventKitAlarm",
    fields: [
      "absoluteDate": field(dateTime), "relativeOffset": field(GraphQLNonNull(GraphQLFloat)),
      "proximity": field(GraphQLNonNull(GraphQLString)),
      "structuredLocation": field(structuredLocation),
    ])
  let proximity = try enumeration("GeofenceProximity", ["ARRIVE", "DEPART"])
  let geofence = try GraphQLObjectType(
    name: "Geofence",
    fields: [
      "title": field(GraphQLString), "latitude": field(GraphQLNonNull(GraphQLFloat)),
      "longitude": field(GraphQLNonNull(GraphQLFloat)),
      "radiusMeters": field(GraphQLNonNull(GraphQLFloat)),
      "proximity": field(GraphQLNonNull(proximity)),
    ])
  let absoluteAlarm = try GraphQLObjectType(
    name: "AbsoluteAlarm", fields: ["at": field(GraphQLNonNull(dateTime))])
  let relativeAlarm = try GraphQLObjectType(
    name: "RelativeAlarm", fields: ["offsetSeconds": field(GraphQLNonNull(GraphQLFloat))])
  let locationAlarm = try GraphQLObjectType(
    name: "LocationAlarm", fields: ["geofence": field(GraphQLNonNull(geofence))])
  let alarmUnion = try GraphQLUnionType(
    name: "ReminderAlarm",
    resolveType: { value, _ in
      guard let value = value as? Map else { throw ServerError.message("Invalid alarm") }
      return try value["__typename"].stringValue()
    }, types: [absoluteAlarm, relativeAlarm, locationAlarm])
  let recurrenceDay = try GraphQLObjectType(
    name: "RecurrenceDay",
    fields: [
      "dayOfTheWeek": field(GraphQLNonNull(GraphQLInt)),
      "weekNumber": field(GraphQLNonNull(GraphQLInt)),
    ])
  let recurrenceEnd = try GraphQLObjectType(
    name: "RecurrenceEnd",
    fields: ["endDate": field(dateTime), "occurrenceCount": field(GraphQLNonNull(GraphQLInt))])
  var recurrenceFields: GraphQLFieldMap = [
    "frequency": field(GraphQLNonNull(GraphQLString)),
    "calendarIdentifier": field(GraphQLNonNull(GraphQLString)),
    "interval": field(GraphQLNonNull(GraphQLInt)),
    "firstDayOfTheWeek": field(GraphQLNonNull(GraphQLInt)),
    "daysOfTheWeek": field(GraphQLNonNull(GraphQLList(GraphQLNonNull(recurrenceDay)))),
    "end": field(recurrenceEnd),
  ]
  for name in [
    "daysOfTheMonth", "daysOfTheYear", "weeksOfTheYear", "monthsOfTheYear", "setPositions",
  ] { recurrenceFields[name] = field(GraphQLNonNull(GraphQLList(GraphQLNonNull(GraphQLInt)))) }
  let recurrence = try GraphQLObjectType(name: "RecurrenceRule", fields: recurrenceFields)
  let frequency = try enumeration("RecurrenceFrequency", ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"])
  let weekday = try enumeration(
    "Weekday", ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"])
  let scheduleDay = try GraphQLObjectType(
    name: "ReminderRecurrenceDay",
    fields: ["day": field(GraphQLNonNull(weekday)), "ordinal": field(GraphQLInt)])
  let scheduleEnd = try GraphQLObjectType(
    name: "ReminderRecurrenceEnd", fields: ["until": field(dateTime), "count": field(GraphQLInt)])
  var scheduleFields: GraphQLFieldMap = [
    "frequency": field(GraphQLNonNull(frequency)), "interval": field(GraphQLNonNull(GraphQLInt)),
    "daysOfWeek": field(GraphQLList(GraphQLNonNull(scheduleDay))), "end": field(scheduleEnd),
  ]
  for name in ["daysOfMonth", "monthsOfYear", "weeksOfYear", "daysOfYear", "setPositions"] {
    scheduleFields[name] = field(GraphQLList(GraphQLNonNull(GraphQLInt)))
  }
  let schedule = try GraphQLObjectType(name: "ReminderRecurrence", fields: scheduleFields)
  let filter = try GraphQLInputObjectType(
    name: "ReminderFilter",
    fields: [
      "query": InputObjectField(type: GraphQLString),
      "accountIds": InputObjectField(type: GraphQLList(GraphQLNonNull(GraphQLID))),
      "flagged": InputObjectField(type: GraphQLBoolean),
      "hasDueDate": InputObjectField(type: GraphQLBoolean),
      "dueFrom": InputObjectField(type: dateTime),
      "listIds": InputObjectField(type: GraphQLList(GraphQLNonNull(GraphQLID))),
      "priorities": InputObjectField(type: GraphQLList(GraphQLNonNull(GraphQLInt))),
      "dueStatus": InputObjectField(type: dueStatus),
      "dueOnOrAfter": InputObjectField(type: GraphQLString),
      "dueBefore": InputObjectField(type: GraphQLString),
      "completed": InputObjectField(type: GraphQLBoolean),
      "nameContains": InputObjectField(type: GraphQLString),
    ])
  let reminder = try GraphQLObjectType(
    name: "Reminder",
    fields: [
      "id": field(GraphQLNonNull(GraphQLID)), "name": field(GraphQLString, key: "name"),
      "body": field(GraphQLString, key: "body"),
      "completed": field(GraphQLBoolean, key: "completed"),
      "priority": field(priority), "creationDate": field(dateTime),
      "completionDate": field(dateTime),
      "modificationDate": field(dateTime, key: "modificationDate"),
      "location": field(GraphQLString),
      "dueDay": field(GraphQLString), "listId": field(GraphQLID), "url": field(url),
      "startDateComponents": field(components), "dueDateComponents": field(components),
      "dueStatus": GraphQLField(
        type: GraphQLNonNull(dueStatus),
        resolve: { source, _, _, _ in
          guard let item = source as? Map else { return nil }
          return try item["dueStatus"].stringValue().uppercased()
        }), "rawAlarms": field(GraphQLNonNull(GraphQLList(GraphQLNonNull(alarm))), key: "alarms"),
      "alarms": GraphQLField(
        type: GraphQLList(GraphQLNonNull(alarmUnion)),
        resolve: { source, _, _, _ in
          guard let source = source as? Map else { return nil }
          return try alarmProjections(source)
        }), "recurrenceRules": field(GraphQLNonNull(GraphQLList(GraphQLNonNull(recurrence)))),
      "recurrence": GraphQLField(
        type: schedule,
        description:
          "A single repeating schedule; null when no recurrence is configured. Multiple rules produce a field error.",
        resolve: { source, _, _, _ in
          guard let source = source as? Map else { return nil }
          return try recurrenceProjection(source)
        }),
      "flagged": GraphQLField(
        type: GraphQLBoolean,
        resolve: { source, _, context, _ in
          guard let item = source as? Map, let context = context as? GraphQLContext else {
            throw ServerError.message("Missing reminder resolver context")
          }
          return try await context.flag(id: item["id"].stringValue())
        }),
      "remindMeDate": GraphQLField(
        type: dateTime,
        resolve: { source, _, context, _ in
          guard let source = source as? Map, let context = context as? GraphQLContext else {
            return nil
          }
          return try await mapValue(
            context.property("script-alerts", id: source["id"].stringValue()))
        }),
      "dueDate": calendarField(dateTime, key: "dueDateComponents", timed: true),
      "startDate": calendarField(dateTime, key: "startDateComponents", timed: true),
      "allDayDueDate": calendarField(localDate, key: "dueDateComponents", timed: false),
      "allDayStartDate": calendarField(localDate, key: "startDateComponents", timed: false),
      "timeZone": GraphQLField(
        type: GraphQLString,
        resolve: { source, _, _, _ in
          guard let source = source as? Map else { return nil }
          let due = try componentValue(source, key: "dueDateComponents")
          let start = try componentValue(source, key: "startDateComponents")
          if let due, let start, due.timeZone != start.timeZone {
            throw ServerError.message(
              "UNSUPPORTED: start and due dates use different time zones; inspect component fields")
          }
          return due?.timeZone ?? start?.timeZone
        }),
    ])
  let pageInfo = try GraphQLObjectType(
    name: "PageInfo",
    fields: [
      "offset": field(GraphQLNonNull(GraphQLInt)), "limit": field(GraphQLNonNull(GraphQLInt)),
      "hasNextPage": field(GraphQLNonNull(GraphQLBoolean)),
      "hasPreviousPage": field(GraphQLNonNull(GraphQLBoolean)),
    ])
  func pageType(_ name: String, _ item: GraphQLObjectType) throws -> GraphQLObjectType {
    try GraphQLObjectType(
      name: name,
      fields: [
        "items": field(GraphQLNonNull(GraphQLList(GraphQLNonNull(item)))),
        "totalCount": field(GraphQLNonNull(GraphQLInt)),
        "pageInfo": field(GraphQLNonNull(pageInfo)),
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
  reminderArgs["sort"] = GraphQLArgument(type: GraphQLNonNull(sort), defaultValue: "ID_ASC")
  let idArg: GraphQLArgumentConfigMap = ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))]
  let listPage = try pageType("ListPage", list)
  let reminderPage = try pageType("ReminderPage", reminder)
  let summary = try GraphQLObjectType(
    name: "ListSummary",
    fields: GraphQLFieldMap(
      uniqueKeysWithValues: [
        "total", "completed", "incomplete", "overdue", "scheduled", "recurring", "withAlarms",
      ].map { ($0, field(GraphQLNonNull(GraphQLInt))) }))
  let resolveContainerType: GraphQLTypeResolve = { value, _ in
    guard let value = value as? Map else { throw ServerError.message("Invalid container") }
    return try value["__typename"].stringValue()
  }
  let listContainer = try GraphQLUnionType(
    name: "ListContainer", resolveType: resolveContainerType, types: [account, list])
  let reminderContainer = try GraphQLUnionType(
    name: "ReminderContainer", resolveType: resolveContainerType, types: [list, reminder])
  func containerField(_ type: GraphQLUnionType, command: String) -> GraphQLField {
    GraphQLField(
      type: type,
      resolve: { source, _, context, _ in
        guard let source = source as? Map, let context = context as? GraphQLContext else {
          return nil
        }
        let reference = try await context.property(command, id: source["id"].stringValue())
        let id = try reference["id"].stringValue()
        let kind = try reference["kind"].stringValue()
        let data = try await context.inventory()
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
          throw ServerError.message(
            "Container is outside the accessible inventory or changed during the read")
        }
        result["__typename"] = Map(kind)
        return result
      })
  }
  var accountFields = try account.fields()
  accountFields["lists"] = GraphQLField(
    type: listPage, args: listArgs,
    resolve: { source, args, context, _ in
      guard let source = source as? Map else { return nil }
      let id = try source["id"].stringValue()
      return try await listSearchPage(inventory(context), args: args, accountID: id)
    })
  accountFields["reminders"] = GraphQLField(
    type: reminderPage, args: reminderArgs,
    resolve: { source, args, context, _ in
      guard let source = source as? Map else { return nil }
      let id = try source["id"].stringValue()
      let data = try await inventory(context)
      return try await searchPage(
        data, args: args, context: context,
        scope: Set(data.lists.filter { $0.source.id == id }.map(\.id)))
    })
  account.fields = { accountFields }
  var listFields = try list.fields()
  listFields["container"] = containerField(listContainer, command: "script-list-containers")
  listFields["account"] = GraphQLField(
    type: account,
    resolve: { source, _, context, _ in
      guard let source = source as? Map else { return nil }
      let id = try source["source"]["id"].stringValue()
      return try await inventory(context).accounts.first { $0.id == id }.map(graphMap)
    })
  listFields["reminders"] = GraphQLField(
    type: reminderPage, args: reminderArgs,
    resolve: { source, args, context, _ in
      guard let source = source as? Map else { return nil }
      return try await searchPage(
        inventory(context), args: args, context: context, scope: [source["id"].stringValue()])
    })
  listFields["summary"] = GraphQLField(
    type: summary,
    resolve: { source, _, context, _ in
      guard let source = source as? Map else { return nil }
      return try await graphMap(summarize(inventory(context), listId: source["id"].stringValue()))
    })
  list.fields = { listFields }
  var reminderFields = try reminder.fields()
  reminderFields["container"] = containerField(
    reminderContainer, command: "script-reminder-containers")
  reminderFields["list"] = GraphQLField(
    type: list,
    resolve: { source, _, context, _ in
      guard let source = source as? Map, let id = try? source["listId"].stringValue() else {
        return nil
      }
      return try await inventory(context).lists.first { $0.id == id }.map(graphMap)
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
          resolve: { _, _, context, _ in try await graphMaps(inventory(context).accounts) }),
        "account": GraphQLField(
          type: account, args: idArg,
          resolve: { _, args, context, _ in
            let id = try args["id"].stringValue()
            return try await inventory(context).accounts.first { $0.id == id }.map(graphMap)
          }),
        "lists": GraphQLField(
          type: listPage, args: listArgs,
          resolve: { _, args, context, _ in try await listSearchPage(inventory(context), args: args)
          }),
        "list": GraphQLField(
          type: list, args: idArg,
          resolve: { _, args, context, _ in
            let id = try args["id"].stringValue()
            return try await inventory(context).lists.first { $0.id == id }.map(graphMap)
          }),
        "reminders": GraphQLField(
          type: reminderPage, args: reminderArgs,
          resolve: { _, args, context, _ in
            try await searchPage(inventory(context), args: args, context: context)
          }),
        "reminder": GraphQLField(
          type: reminder, args: idArg,
          resolve: { _, args, context, _ in
            let id = try args["id"].stringValue()
            return try await inventory(context).reminders.first { $0.id == id }.map(graphMap)
          }),
        "defaultAccount": GraphQLField(
          type: account,
          resolve: { _, _, context, _ in try await inventory(context).defaultAccount.map(graphMap) }
        ),
        "defaultList": GraphQLField(
          type: list,
          resolve: { _, _, context, _ in try await inventory(context).defaultList.map(graphMap) }),
      ]), mutation: mutation)
}
