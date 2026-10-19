import Foundation

func metricEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
actor MetricsCollector {
  private var snapshot: String?
  private var failure = "Metrics collection has not completed yet"

  func cachedSnapshot() throws -> String {
    guard let snapshot else { throw ServerError.internalError(failure) }
    return snapshot
  }

  func run(intervalSeconds: Int) async {
    var failed = false
    while !Task.isCancelled {
      do {
        snapshot = try await collectMetrics()
        if failed { serverLogger.info("Metrics collection recovered") }
        failed = false
      } catch {
        logFailure("Metrics collection failed", error: error)
        failed = true
        snapshot = nil
        failure = "Metrics collection failed: \(error)"
      }
      do {
        try await Task.sleep(for: .seconds(failed ? min(60, intervalSeconds) : intervalSeconds))
      } catch { return }
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
