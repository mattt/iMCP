import Foundation
import XCTest

final class CalendarSelectionTests: XCTestCase {
    private struct Fake: CalendarSelectable, Equatable {
        var selectionIdentifier: String
        var selectionTitle: String
    }

    private let work = Fake(selectionIdentifier: "id-work", selectionTitle: "Work")
    private let home = Fake(selectionIdentifier: "id-home", selectionTitle: "Home")
    private let birthdays = Fake(selectionIdentifier: "id-birthdays", selectionTitle: "Birthdays")
    private var all: [Fake] { [work, home, birthdays] }

    func testEveryCalendarIsSelectedByDefault() {
        let selection = CalendarSelection()
        XCTAssertEqual(selection.filter(all), all)
    }

    func testDeselectedCalendarIsFilteredOut() {
        var selection = CalendarSelection()
        selection.setSelected(false, for: home.selectionIdentifier)
        XCTAssertEqual(selection.filter(all), [work, birthdays])
    }

    func testNewCalendarsFollowTheAutomaticSetting() {
        var selection = CalendarSelection()
        selection.setSelected(false, for: home.selectionIdentifier)
        XCTAssertTrue(selection.isSelected("id-added-later"))

        selection.setShowsNewCalendars(false, existing: all.map(\.selectionIdentifier))
        XCTAssertFalse(selection.isSelected("id-added-later"))
        // Calendars that existed keep their choice.
        XCTAssertTrue(selection.isSelected(work.selectionIdentifier))
        XCTAssertFalse(selection.isSelected(home.selectionIdentifier))

        selection.setSelected(true, for: "id-added-later")
        XCTAssertTrue(selection.isSelected("id-added-later"))
    }

    func testTurningAutomaticBackOnKeepsExplicitChoices() {
        var selection = CalendarSelection()
        selection.setShowsNewCalendars(false, existing: all.map(\.selectionIdentifier))
        selection.setSelected(false, for: birthdays.selectionIdentifier)
        selection.setShowsNewCalendars(true, existing: all.map(\.selectionIdentifier))
        XCTAssertFalse(selection.isSelected(birthdays.selectionIdentifier))
        XCTAssertTrue(selection.isSelected("id-added-later"))
    }

    func testChoicesForMissingCalendarsAreHarmless() {
        var selection = CalendarSelection()
        selection.setSelected(false, for: "id-gone")
        XCTAssertEqual(selection.filter(all), all)
        // The choice returns with the calendar.
        XCTAssertFalse(selection.isSelected("id-gone"))
    }

    func testResolveMatchesTitlesCaseInsensitively() throws {
        let selection = CalendarSelection()
        XCTAssertEqual(try selection.resolve(names: ["WORK", "home"], in: all), [work, home])
    }

    func testResolveRejectsAnUnselectedCalendar() {
        var selection = CalendarSelection()
        selection.setSelected(false, for: home.selectionIdentifier)
        XCTAssertThrowsError(try selection.resolve(names: ["Work", "Home"], in: all)) {
            XCTAssertEqual($0 as? CalendarSelectionError, .notShared("Home"))
        }
    }

    func testResolveUsesTheSelectedCalendarWhenTitlesRepeat() throws {
        let otherWork = Fake(selectionIdentifier: "id-work-2", selectionTitle: "Work")
        var selection = CalendarSelection()
        selection.setSelected(false, for: work.selectionIdentifier)
        XCTAssertEqual(try selection.resolve(names: ["Work"], in: [work, otherWork]), [otherWork])
    }

    func testResolveIgnoresNamesThatMatchNothing() throws {
        XCTAssertEqual(try CalendarSelection().resolve(names: ["Nope"], in: all), [])
    }

    func testRequireRefusesAnUnselectedCalendar() throws {
        var selection = CalendarSelection()
        selection.setSelected(false, for: home.selectionIdentifier)
        try selection.require(work)
        XCTAssertThrowsError(try selection.require(home)) {
            XCTAssertEqual($0 as? CalendarSelectionError, .notShared("Home"))
        }
    }

    func testStorePersistsTheSelection() throws {
        let suite = "CalendarSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CalendarSelectionStore(defaults: defaults)
        XCTAssertEqual(store.selection, CalendarSelection())

        var selection = CalendarSelection()
        selection.setSelected(false, for: home.selectionIdentifier)
        selection.setShowsNewCalendars(false, existing: all.map(\.selectionIdentifier))
        store.selection = selection
        XCTAssertEqual(CalendarSelectionStore(defaults: defaults).selection, selection)
    }
}
