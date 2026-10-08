import Foundation

func metricEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
actor MetricsCollector {
  private var snapshot: String?
  private var failure = "Metrics collection has not completed yet"

  func cachedSnapshot() throws -> String {
    guard let snapshot else { throw ServerError.message(failure) }
    return snapshot
  }

  func run(intervalSeconds: Int) async {
    while !Task.isCancelled {
      do {
        snapshot = try await collectMetrics()
      } catch {
        snapshot = nil
        failure = "Metrics collection failed: \(error)"
      }
      do {
        try await Task.sleep(for: .seconds(intervalSeconds))
      } catch { return }
    }
  }
}

func collectMetrics() async throws -> String {
  let data = try await readInventory(includeFlags: false)
  let lists = data.orderedLists
  let fetched = data.reminders
  let listIDs = Set(lists.map { $0.id })
  var seen = Set<String>()
  var reminders: [ReminderRecord] = []
  for item in fetched {
    guard let listID = item.listId, listIDs.contains(listID) else {
      throw ServerError.message("Reminder inventory changed during collection; retry the scrape")
    }
    if seen.insert(item.id).inserted { reminders.append(item) }
  }
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
  let families = [
    ("reminders_items", "status", ["incomplete", "completed"]),
    ("reminders_incomplete_items_by_priority", "priority", ["none", "low", "medium", "high"]),
    (
      "reminders_incomplete_items_by_due_status", "due_status",
      ["overdue", "today", "future", "unscheduled"]
    ),
  ]
  for (name, label, categories) in families {
    family(name, "Number of reminders in each list by \(label).")
    for list in lists {
      let id = list.id
      let source = list.source
      let items = reminders.filter { $0.listId == id }
      var counts = Dictionary(uniqueKeysWithValues: categories.map { ($0, 0) })
      do {
        for item in items {
          let completed = item.completed
          if label != "status" && completed { continue }
          let category: String
          if label == "status" {
            category = completed ? "completed" : "incomplete"
          } else if label == "priority" {
            let priority = item.priority
            guard (0...9).contains(priority) else {
              throw ServerError.message("Out-of-range priority")
            }
            category =
              priority == 0 ? "none" : priority < 5 ? "high" : priority == 5 ? "medium" : "low"
          } else {
            let status = item.dueStatus.rawValue
            guard categories.contains(status) else {
              throw ServerError.message("Unclassifiable EventKit due components")
            }
            category = status
          }
          counts[category, default: 0] += 1
        }
      } catch {
        if label == "due_status" || label == "priority" { continue }
        throw error
      }
      for category in categories {
        lines.append(
          "\(name){account_id=\"\(metricEscape(source.id))\",list_id=\"\(metricEscape(id))\",\(label)=\"\(category)\"} \(counts[category]!)"
        )
      }
    }
  }
  return lines.joined(separator: "\n") + "\n"
}
