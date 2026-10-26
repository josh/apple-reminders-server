import Foundation

import struct os.OSAllocatedUnfairLock

private let processStart = Date()
private struct RequestKey: Hashable { let route: String, code: Int }
private let requestCounts = OSAllocatedUnfairLock<[RequestKey: Int]>(initialState: [:])

func recordRequest(route: String, code: Int) {
  requestCounts.withLock { $0[RequestKey(route: route, code: code), default: 0] += 1 }
}

// Prometheus metric types the exposition uses.
enum MetricType: String { case counter, gauge }
private func familyHeader(_ name: String, _ type: MetricType, _ help: String) -> [String] {
  ["# HELP \(name) \(help)", "# TYPE \(name) \(type.rawValue)"]
}

// Served even when the EventKit gauges are not: a failed EventKit read must not
// blank the request and liveness series that explain it.
func runtimeMetrics(eventKitUp: Bool, authorizing: Bool) -> String {
  var lines: [String] = []
  lines += familyHeader(
    "process_start_time_seconds", .gauge,
    "Start time of the process since the Unix epoch; a change is a restart.")
  lines.append("process_start_time_seconds \(Int(processStart.timeIntervalSince1970))")
  lines += familyHeader(
    "reminders_http_requests_total", .counter, "HTTP requests answered, by route and status code.")
  let counts = requestCounts.withLock { $0 }
  for (key, count) in counts.sorted(by: {
    ($0.key.route, $0.key.code) < ($1.key.route, $1.key.code)
  }) {
    lines.append(
      "reminders_http_requests_total{route=\"\(metricEscape(key.route))\",code=\"\(key.code)\"} \(count)"
    )
  }
  lines += familyHeader(
    "reminders_main_actor_heartbeat_age_seconds", .gauge,
    "Seconds since the main actor last ran a watchdog heartbeat; the process exits past \(mainActorWatchdogLimit.components.seconds)."
  )
  lines.append(
    "reminders_main_actor_heartbeat_age_seconds \(mainActorHeartbeatAge() / .seconds(1))")
  lines += familyHeader(
    "reminders_authorization_pending", .gauge,
    "1 while the startup Reminders access request has not finished; /graphql and /mcp answer 503 meanwhile."
  )
  lines.append("reminders_authorization_pending \(authorizing ? 1 : 0)")
  lines += familyHeader(
    "reminders_eventkit_up", .gauge,
    "1 when the last background EventKit read succeeded and its gauges follow.")
  lines.append("reminders_eventkit_up \(eventKitUp ? 1 : 0)")
  return lines.joined(separator: "\n") + "\n"
}

func metricEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
actor MetricsCollector {
  private(set) var exposition: String?

  func run(interval: Duration) async {
    var failed = false
    var delay = interval
    while !Task.isCancelled {
      do {
        exposition = try await collectMetrics()
        if failed { serverLogger.info("Metrics collection recovered") }
        failed = false
        delay = interval
      } catch {
        logFailure("Metrics collection failed", error: error)
        exposition = nil
        // Retry after a minute, doubling toward the interval so a lasting failure stays quiet.
        delay = failed ? min(delay * 2, interval) : min(.seconds(60), interval)
        failed = true
      }
      do { try await Task.sleep(for: delay) } catch { return }
    }
  }
}

// reminders_items labels; case order is the exposition order.
private enum ItemStatus: String, CaseIterable { case incomplete, completed }
private enum PriorityBand: String, CaseIterable {
  case none, high, medium, low
  // EventKit priorities: 0 none, 1-4 high, 5 medium, 6-9 low.
  init(priority: Int) {
    self = priority == 0 ? .none : priority < 5 ? .high : priority == 5 ? .medium : .low
  }
}
private struct ItemBucket: Hashable {
  let status: ItemStatus
  let priority: PriorityBand
  let due: DueStatus
}
extension ItemBucket {
  init(_ item: ReminderRecord) {
    self.init(
      status: item.completed ? .completed : .incomplete,
      priority: PriorityBand(priority: item.priority), due: item.dueStatus)
  }
}

func collectMetrics() async throws -> String {
  let data = try await readRemindersData()
  let lists = data.lists
  let reminders = data.reminders
  let accounts = Set(lists.map { $0.source.id })
  var lines: [String] = []
  func family(_ name: String, _ help: String) { lines += familyHeader(name, .gauge, help) }
  family("reminders_accounts", "Number of accounts with accessible reminder lists.")
  lines.append("reminders_accounts \(accounts.count)")
  family("reminders_lists", "Number of accessible reminder lists in an account.")
  for account in accounts.sorted() {
    let count = lists.filter { $0.source.id == account }.count
    lines.append("reminders_lists{account_id=\"\(metricEscape(account))\"} \(count)")
  }
  family("reminders_list_info", "Reminder list identity and name, with value 1.")
  for list in lists {
    let source = list.source
    lines.append(
      "reminders_list_info{account_id=\"\(metricEscape(source.id))\",list_id=\"\(metricEscape(list.id))\",name=\"\(metricEscape(list.name))\"} 1"
    )
  }
  for (name, key, what) in [
    ("reminders_scheduled_items", \ListSummary.scheduled, "a due date"),
    ("reminders_recurring_items", \ListSummary.recurring, "stored recurrence rules"),
    ("reminders_items_with_alarms", \ListSummary.withAlarms, "alarms"),
  ] {
    family(name, "Reminders with \(what) in each list, including completed ones.")
    for list in lists {
      let count = summarize(data, listId: list.id)[keyPath: key]
      lines.append(
        "\(name){account_id=\"\(metricEscape(list.source.id))\",list_id=\"\(metricEscape(list.id))\"} \(count)"
      )
    }
  }
  family(
    "reminders_items",
    "Number of reminders by completion status, priority (none 0, high 1-4, medium 5, low 6-9), and deadline status."
  )
  for list in lists {
    var counts: [ItemBucket: Int] = [:]
    for item in reminders where item.listId == list.id {
      counts[ItemBucket(item), default: 0] += 1
    }
    for status in ItemStatus.allCases {
      for priority in PriorityBand.allCases {
        for dueStatus in DueStatus.allCases {
          let count =
            counts[ItemBucket(status: status, priority: priority, due: dueStatus), default: 0]
          lines.append(
            "reminders_items{account_id=\"\(metricEscape(list.source.id))\",list_id=\"\(metricEscape(list.id))\",status=\"\(status.rawValue)\",priority=\"\(priority.rawValue)\",due_status=\"\(dueStatus.rawValue)\"} \(count)"
          )
        }
      }
    }
  }
  return lines.joined(separator: "\n") + "\n"
}
