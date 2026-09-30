import Foundation

struct SyncReminder {
  let defaults: UserDefaults
  init(defaults: UserDefaults = .standard, now: Date = Date()) {
    self.defaults = defaults
    if defaults.object(forKey: "syncReminderReference") == nil {
      defaults.set(now, forKey: "syncReminderReference")
    }
  }
  var interval: Int { defaults.integer(forKey: "scheduleSeconds") }
  func isDue(at now: Date = Date()) -> Bool {
    guard interval > 0, let reference = defaults.object(forKey: "syncReminderReference") as? Date else { return false }
    return now.timeIntervalSince(reference) >= Double(interval)
  }
  func acknowledge(at now: Date = Date()) {
    defaults.set(now, forKey: "syncReminderReference")
  }
  func update(_ interval: Int, at now: Date = Date()) {
    defaults.set(interval, forKey: "scheduleSeconds")
    acknowledge(at: now)
  }
}
