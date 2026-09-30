import Foundation
import XCTest
@testable import KeybridgeConnect

final class SyncReminderTests: XCTestCase {
  func testWeeklyReminderSurvivesRestartsAndStaysDueUntilAcknowledged() throws {
    let suite = "keybridge-reminder-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let start = Date(timeIntervalSince1970: 1790000000)
    let reminder = SyncReminder(defaults: defaults, now: start)
    reminder.update(604800, at: start)
    XCTAssertFalse(reminder.isDue(at: start.addingTimeInterval(604799)))
    let reopened = SyncReminder(defaults: defaults, now: start.addingTimeInterval(604800))
    XCTAssertEqual(reopened.interval, 604800)
    XCTAssertTrue(reopened.isDue(at: start.addingTimeInterval(604800)))
    XCTAssertTrue(reopened.isDue(at: start.addingTimeInterval(1209600)))
    reopened.acknowledge(at: start.addingTimeInterval(1209600))
    XCTAssertFalse(reopened.isDue(at: start.addingTimeInterval(1209601)))
    XCTAssertTrue(reopened.isDue(at: start.addingTimeInterval(1814400)))
    reopened.update(0, at: start)
    XCTAssertFalse(reopened.isDue(at: start.addingTimeInterval(1814400)))
  }
}
