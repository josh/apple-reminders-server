import Foundation
import struct os.OSAllocatedUnfairLock

private let processStart = Date()
private struct RequestKey: Hashable { let route: String, code: Int }
private let requestCounts = OSAllocatedUnfairLock<[RequestKey: Int]>(initialState: [:])

func recordRequest(route: String, code: Int) {
  requestCounts.withLock { $0[RequestKey(route: route, code: code), default: 0] += 1 }
}

// Served even when the inventory snapshot is not: a failed EventKit read must not
// blank the request and liveness series that explain it.
func runtimeMetrics(inventoryUp: Bool, authorizing: Bool) -> String {
  var lines: [String] = []
  func family(_ name: String, _ type: String, _ help: String) {
    lines += ["# HELP \(name) \(help)", "# TYPE \(name) \(type)"]
  }
  family(
    "process_start_time_seconds", "gauge",
    "Start time of the process since the Unix epoch; a change is a restart.")
  lines.append("process_start_time_seconds \(Int(processStart.timeIntervalSince1970))")
  family(
    "reminders_http_requests_total", "counter", "HTTP requests answered, by route and status code.")
  let counts = requestCounts.withLock { $0 }
  for (key, count) in counts.sorted(by: {
    ($0.key.route, $0.key.code) < ($1.key.route, $1.key.code)
  }) {
    lines.append(
      "reminders_http_requests_total{route=\"\(metricEscape(key.route))\",code=\"\(key.code)\"} \(count)"
    )
  }
  family(
    "reminders_main_actor_heartbeat_age_seconds", "gauge",
    "Seconds since the main actor last ran a watchdog heartbeat; the process exits past 120.")
  let age = mainActorHeartbeatAge().components
  lines.append(
    "reminders_main_actor_heartbeat_age_seconds \(Double(age.seconds) + Double(age.attoseconds) / 1e18)"
  )
  family(
    "reminders_authorization_pending", "gauge",
    "1 while the startup Reminders access request has not finished.")
  lines.append("reminders_authorization_pending \(authorizing ? 1 : 0)")
  family(
    "reminders_inventory_up", "gauge",
    "1 when the last background EventKit inventory read succeeded and its gauges follow.")
  lines.append("reminders_inventory_up \(inventoryUp ? 1 : 0)")
  return lines.joined(separator: "\n") + "\n"
}

func metricEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
actor MetricsCollector {
  private var snapshot: String?

  func cachedSnapshot() -> String? { snapshot }

  func run(intervalSeconds: Int) async {
    var failed = false
    var delay = intervalSeconds
    while !Task.isCancelled {
      do {
        snapshot = try await collectMetrics()
        if failed { serverLogger.info("Metrics collection recovered") }
        failed = false
        delay = intervalSeconds
      } catch {
        logFailure("Metrics collection failed", error: error)
        snapshot = nil
        // Retry after a minute, doubling toward the interval so a lasting failure stays quiet.
        delay = failed ? min(delay * 2, intervalSeconds) : min(60, intervalSeconds)
        failed = true
      }
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
    }
  }
}

func collectMetrics() async throws -> String {
  let data = try await readInventory()
  let lists = data.lists
  let reminders = data.reminders
  let accounts = Set(lists.map { $0.source.id })
  var lines: [String] = []
  func family(_ name: String, _ help: String) {
    lines += ["# HELP \(name) \(help)", "# TYPE \(name) gauge"]
  }
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
  for (name, key) in [
    ("reminders_scheduled_items", \ListSummary.scheduled),
    ("reminders_recurring_items", \ListSummary.recurring),
    ("reminders_items_with_alarms", \ListSummary.withAlarms),
  ] {
    family(name, "Number of matching reminders in each list, including completed reminders.")
    for list in lists {
      let count = summarize(data, listId: list.id)[keyPath: key]
      lines.append(
        "\(name){account_id=\"\(metricEscape(list.source.id))\",list_id=\"\(metricEscape(list.id))\"} \(count)"
      )
    }
  }
  family(
    "reminders_items", "Number of reminders by completion status, priority, and deadline status.")
  for list in lists {
    var counts: [String: Int] = [:]
    for item in reminders where item.listId == list.id {
      let status = item.completed ? "completed" : "incomplete"
      let priority =
        item.priority == 0
        ? "none" : item.priority < 5 ? "high" : item.priority == 5 ? "medium" : "low"
      counts["\(status)/\(priority)/\(item.dueStatus.rawValue)", default: 0] += 1
    }
    for status in ["incomplete", "completed"] {
      for priority in ["none", "high", "medium", "low"] {
        for dueStatus in DueStatus.allCases {
          let count = counts["\(status)/\(priority)/\(dueStatus.rawValue)", default: 0]
          lines.append(
            "reminders_items{account_id=\"\(metricEscape(list.source.id))\",list_id=\"\(metricEscape(list.id))\",status=\"\(status)\",priority=\"\(priority)\",due_status=\"\(dueStatus.rawValue)\"} \(count)"
          )
        }
      }
    }
  }
  return lines.joined(separator: "\n") + "\n"
}
