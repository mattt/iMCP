import Foundation
import XCTest

final class RemindersQueryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    // MARK: - Due dates

    func testDateOnlyIsAllDay() throws {
        let due = try RemindersQuery.parseDue("2026-04-15", calendar: calendar)
        XCTAssertTrue(due.isAllDay)
        XCTAssertEqual(due.components.year, 2026)
        XCTAssertEqual(due.components.month, 4)
        XCTAssertEqual(due.components.day, 15)
        XCTAssertNil(due.components.hour)
    }

    func testDateAndTimeIsTimedLocal() throws {
        let due = try RemindersQuery.parseDue("2026-04-15 14:30", calendar: calendar)
        XCTAssertFalse(due.isAllDay)
        XCTAssertEqual(due.components.hour, 14)
        XCTAssertEqual(due.components.minute, 30)
        let withT = try RemindersQuery.parseDue("2026-04-15T14:30:00", calendar: calendar)
        XCTAssertEqual(withT.components.hour, 14)
    }

    func testOffsetIsConvertedToLocalTime() throws {
        // 18:00Z on 2026-01-15 is 13:00 in New York (UTC-5).
        let zulu = try RemindersQuery.parseDue("2026-01-15T18:00:00Z", calendar: calendar)
        XCTAssertEqual(zulu.components.hour, 13)
        XCTAssertEqual(zulu.components.day, 15)
        // 23:30+02:00 on the 15th is 21:30Z, 16:30 local.
        let offset = try RemindersQuery.parseDue("2026-01-15T23:30:00+02:00", calendar: calendar)
        XCTAssertEqual(offset.components.hour, 16)
        XCTAssertEqual(offset.components.minute, 30)
        // Crossing midnight changes the day.
        let nextDay = try RemindersQuery.parseDue("2026-01-16T02:00:00Z", calendar: calendar)
        XCTAssertEqual(nextDay.components.day, 15)
        XCTAssertEqual(nextDay.components.hour, 21)
    }

    func testInvalidDatesAreRejected() {
        for text in ["tomorrow", "2026-02-30", "2026-13-01", "2026-04-15 25:00", "2026-04-15 10:61", "", "15/04/2026"] {
            XCTAssertThrowsError(try RemindersQuery.parseDue(text, calendar: calendar), text) { error in
                XCTAssertEqual((error as? RemindersInputError)?.code, "invalid_due_date")
            }
        }
    }

    func testCompletionDate() throws {
        let date = try RemindersQuery.parseCompletionDate("2026-05-27 09:30", calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(parts.day, 27)
        XCTAssertEqual(parts.hour, 9)
        let midnight = try RemindersQuery.parseCompletionDate("2026-05-27", calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: midnight), 0)
        XCTAssertThrowsError(try RemindersQuery.parseCompletionDate("soon", calendar: calendar)) {
            XCTAssertEqual(($0 as? RemindersInputError)?.code, "invalid_completion_date")
        }
    }

    // MARK: - Priority

    func testPriorityNamesAndNumbers() {
        XCTAssertEqual(RemindersQuery.priorityNumber(name: "high"), 1)
        XCTAssertEqual(RemindersQuery.priorityNumber(name: "Medium"), 5)
        XCTAssertEqual(RemindersQuery.priorityNumber(name: "low"), 9)
        XCTAssertEqual(RemindersQuery.priorityNumber(name: "none"), 0)
        XCTAssertNil(RemindersQuery.priorityNumber(name: "urgent"))
        XCTAssertEqual(RemindersQuery.priorityNumber(apple: 4), 4)
        XCTAssertNil(RemindersQuery.priorityNumber(apple: 10))
        XCTAssertNil(RemindersQuery.priorityNumber(apple: -1))
        XCTAssertEqual(RemindersQuery.priorityName(for: 0), "none")
        XCTAssertEqual(RemindersQuery.priorityName(for: 3), "high")
        XCTAssertEqual(RemindersQuery.priorityName(for: 5), "medium")
        XCTAssertEqual(RemindersQuery.priorityName(for: 7), "low")
    }

    // MARK: - Recurrence

    private func rule(_ text: String) throws -> RemindersQuery.RecurrenceSpec {
        guard case .rule(let spec) = try RemindersQuery.parseRecurrence(text) else {
            XCTFail("\(text) parsed as clear")
            throw RemindersInputError(code: "x", message: "x")
        }
        return spec
    }

    func testSimpleFrequencies() throws {
        XCTAssertEqual(try rule("daily"), .init(frequency: .daily))
        XCTAssertEqual(try rule("Weekly"), .init(frequency: .weekly))
        XCTAssertEqual(try rule("monthly").interval, 1)
        XCTAssertEqual(try rule("yearly").frequency, .yearly)
    }

    func testIntervalsAndWeekdays() throws {
        XCTAssertEqual(try rule("daily x2").interval, 2)
        XCTAssertEqual(try rule("weekly x3 mon,wed,fri").weekdays.map(\.weekday), [2, 4, 6])
        XCTAssertEqual(try rule("weekly sunday,saturday").weekdays.map(\.weekday), [1, 7])
        XCTAssertEqual(try rule("weekly mon,wed,fri").weekdays.map(\.ordinal), [0, 0, 0])
    }

    func testMonthDaysAndOrdinalWeekdays() throws {
        XCTAssertEqual(try rule("monthly 1,15").monthDays, [1, 15])
        XCTAssertEqual(try rule("monthly -1").monthDays, [-1])
        XCTAssertEqual(
            try rule("monthly 4th-fri").weekdays,
            [.init(weekday: 6, ordinal: 4)]
        )
        XCTAssertEqual(
            try rule("monthly last-fri").weekdays,
            [.init(weekday: 6, ordinal: -1)]
        )
        XCTAssertEqual(try rule("monthly -2-mon").weekdays, [.init(weekday: 2, ordinal: -2)])
        let both = try rule("monthly x2 1st-mon,3rd-mon")
        XCTAssertEqual(both.interval, 2)
        XCTAssertEqual(both.weekdays.map(\.ordinal), [1, 3])
    }

    func testClearWords() throws {
        for word in ["clear", "none", "never", "NEVER"] {
            XCTAssertEqual(try RemindersQuery.parseRecurrence(word), .clear)
        }
    }

    func testBadRecurrenceIsRejected() {
        let bad = [
            "", "sometimes", "weekly funday", "monthly 4st-fri", "monthly 1,4th-fri",
            "monthly 0", "monthly 32", "daily x0", "daily x1000", "daily mon", "weekly 4th-fri",
            "monthly -6-fri", "daily x2 x3", "weekly mon tue",
        ]
        for text in bad {
            XCTAssertThrowsError(try RemindersQuery.parseRecurrence(text), text) { error in
                XCTAssertEqual((error as? RemindersInputError)?.code, "invalid_recurrence")
            }
        }
    }

    // MARK: - Alarms

    func testRelativeAndAbsoluteAlarms() throws {
        XCTAssertEqual(try RemindersQuery.parseAlarm("15m", calendar: calendar), .relative(minutes: 15))
        XCTAssertEqual(try RemindersQuery.parseAlarm("1h", calendar: calendar), .relative(minutes: 60))
        XCTAssertEqual(try RemindersQuery.parseAlarm("2d", calendar: calendar), .relative(minutes: 2880))
        XCTAssertEqual(try RemindersQuery.parseAlarm("1w", calendar: calendar), .relative(minutes: 10080))
        XCTAssertEqual(try RemindersQuery.parseAlarm("clear", calendar: calendar), .clear)
        guard case .absolute(let date) = try RemindersQuery.parseAlarm("2026-05-27 09:30", calendar: calendar)
        else { return XCTFail("expected absolute") }
        XCTAssertEqual(calendar.component(.hour, from: date), 9)
        XCTAssertThrowsError(try RemindersQuery.parseAlarm("soonish", calendar: calendar)) {
            XCTAssertEqual(($0 as? RemindersInputError)?.code, "invalid_alarm")
        }
    }

    // MARK: - Search and paging

    func testSearchIgnoresCaseAndAccents() {
        XCTAssertTrue(RemindersQuery.matches(query: "cafe", fields: ["Meet at Café", nil]))
        XCTAssertTrue(RemindersQuery.matches(query: "CAFÉ", fields: ["cafe"]))
        XCTAssertTrue(RemindersQuery.matches(query: "macstories.net", fields: [nil, nil, "https://MacStories.net/x"]))
        XCTAssertTrue(RemindersQuery.matches(query: "invoice", fields: ["title", "see the Invoice notes"]))
        XCTAssertFalse(RemindersQuery.matches(query: "milk", fields: ["eggs", nil]))
    }

    func testSearchTreatsWildcardCharactersAsText() {
        XCTAssertTrue(RemindersQuery.matches(query: "50%", fields: ["Save 50% today"]))
        XCTAssertFalse(RemindersQuery.matches(query: "50%", fields: ["Save 500 today"]))
        XCTAssertTrue(RemindersQuery.matches(query: "a_b", fields: ["a_b"]))
        XCTAssertFalse(RemindersQuery.matches(query: "a_b", fields: ["axb"]))
        XCTAssertTrue(RemindersQuery.matches(query: "back\\slash", fields: ["back\\slash"]))
    }

    func testPagingFieldsAndWalk() throws {
        let items = Array(0 ..< 7)
        let first = RemindersQuery.page(items, limit: 3, offset: 0)
        XCTAssertEqual(first.items, [0, 1, 2])
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.total, 7)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.nextOffset, 3)

        let last = RemindersQuery.page(items, limit: 3, offset: 6)
        XCTAssertEqual(last.items, [6])
        XCTAssertFalse(last.hasMore)
        XCTAssertNil(last.nextOffset)

        let beyond = RemindersQuery.page(items, limit: 3, offset: 50)
        XCTAssertEqual(beyond.items, [])
        XCTAssertEqual(beyond.total, 7)
        XCTAssertFalse(beyond.hasMore)

        var collected: [Int] = []
        var offset = 0
        while true {
            let page = RemindersQuery.page(items, limit: 2, offset: offset)
            collected += page.items
            guard let next = page.nextOffset else { break }
            offset = next
        }
        XCTAssertEqual(collected, items)
    }

    func testPagingBounds() throws {
        XCTAssertEqual(try RemindersQuery.validatedPaging(limit: nil, offset: nil).limit, 100)
        XCTAssertEqual(try RemindersQuery.validatedPaging(limit: 500, offset: 0).limit, 500)
        XCTAssertThrowsError(try RemindersQuery.validatedPaging(limit: 0, offset: 0))
        XCTAssertThrowsError(try RemindersQuery.validatedPaging(limit: 501, offset: 0))
        XCTAssertThrowsError(try RemindersQuery.validatedPaging(limit: 10, offset: -1))
    }

    // MARK: - Named views

    private func components(_ text: String) throws -> DateComponents {
        try RemindersQuery.parseDue(text, calendar: calendar).components
    }

    /// 2026-06-10 15:00 in New York.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 15))!
    }

    func testTodayView() throws {
        XCTAssertTrue(RemindersQuery.Views.isDueToday(try components("2026-06-10"), now: now, calendar: calendar))
        XCTAssertTrue(RemindersQuery.Views.isDueToday(try components("2026-06-10 08:00"), now: now, calendar: calendar))
        XCTAssertTrue(RemindersQuery.Views.isDueToday(try components("2026-06-10 23:59"), now: now, calendar: calendar))
        XCTAssertFalse(RemindersQuery.Views.isDueToday(try components("2026-06-11"), now: now, calendar: calendar))
        XCTAssertFalse(
            RemindersQuery.Views.isDueToday(try components("2026-06-09 23:59"), now: now, calendar: calendar)
        )
        XCTAssertFalse(RemindersQuery.Views.isDueToday(nil, now: now, calendar: calendar))
    }

    func testOverdueView() throws {
        // An all-day reminder due today is not overdue; yesterday's is.
        XCTAssertFalse(RemindersQuery.Views.isOverdue(try components("2026-06-10"), now: now, calendar: calendar))
        XCTAssertTrue(RemindersQuery.Views.isOverdue(try components("2026-06-09"), now: now, calendar: calendar))
        // A timed reminder is overdue once its time has passed.
        XCTAssertTrue(RemindersQuery.Views.isOverdue(try components("2026-06-10 14:59"), now: now, calendar: calendar))
        XCTAssertFalse(RemindersQuery.Views.isOverdue(try components("2026-06-10 15:01"), now: now, calendar: calendar))
        XCTAssertFalse(RemindersQuery.Views.isOverdue(nil, now: now, calendar: calendar))
    }

    func testUpcomingWindow() throws {
        // days 1 covers today and tomorrow.
        XCTAssertTrue(
            RemindersQuery.Views.isUpcoming(try components("2026-06-10"), days: 1, now: now, calendar: calendar)
        )
        XCTAssertTrue(
            RemindersQuery.Views.isUpcoming(try components("2026-06-11 23:30"), days: 1, now: now, calendar: calendar)
        )
        XCTAssertFalse(
            RemindersQuery.Views.isUpcoming(try components("2026-06-12"), days: 1, now: now, calendar: calendar)
        )
        XCTAssertTrue(
            RemindersQuery.Views.isUpcoming(try components("2026-06-17"), days: 7, now: now, calendar: calendar)
        )
        XCTAssertFalse(
            RemindersQuery.Views.isUpcoming(try components("2026-06-18"), days: 7, now: now, calendar: calendar)
        )
        XCTAssertFalse(
            RemindersQuery.Views.isUpcoming(try components("2026-06-09"), days: 7, now: now, calendar: calendar)
        )
        XCTAssertEqual(try RemindersQuery.validatedUpcomingDays(nil), 7)
        XCTAssertThrowsError(try RemindersQuery.validatedUpcomingDays(0))
        XCTAssertThrowsError(try RemindersQuery.validatedUpcomingDays(366))
    }

    // MARK: - Batches

    func testBatchPlanDeduplicatesAndBounds() throws {
        let plan = try RemindersQuery.batchPlan(["a", "b", "a", "c", "b"])
        XCTAssertEqual(plan.unique, ["a", "b", "c"])
        XCTAssertEqual(plan.duplicatesIgnored, ["a", "b"])

        XCTAssertNoThrow(try RemindersQuery.batchPlan((0 ..< 50).map(String.init)))
        XCTAssertThrowsError(try RemindersQuery.batchPlan((0 ..< 51).map(String.init))) {
            XCTAssertEqual(($0 as? RemindersInputError)?.code, "batch_too_large")
        }
        XCTAssertThrowsError(try RemindersQuery.batchPlan([])) {
            XCTAssertEqual(($0 as? RemindersInputError)?.code, "empty_batch")
        }
        XCTAssertThrowsError(try RemindersQuery.batchPlan(["a", ""]))
    }

    func testBatchOverallStatus() {
        XCTAssertEqual(RemindersQuery.batchOverallStatus([.succeeded, .succeeded]), "completed")
        XCTAssertEqual(RemindersQuery.batchOverallStatus([.failed, .skipped]), "failed")
        XCTAssertEqual(RemindersQuery.batchOverallStatus([.succeeded, .failed]), "partial")
        XCTAssertEqual(RemindersQuery.batchOverallStatus([.uncertain]), "partial")
        XCTAssertEqual(RemindersQuery.batchOverallStatus([.succeeded, .uncertain, .skipped]), "partial")
    }

    // MARK: - Colors

    func testListColors() throws {
        XCTAssertEqual(try RemindersQuery.parseListColor("Blue").hex, "#007AFF")
        XCTAssertEqual(try RemindersQuery.parseListColor("#ff8d28").hex, "#FF8D28")
        XCTAssertEqual(try RemindersQuery.parseListColor("grey"), try RemindersQuery.parseListColor("gray"))
        XCTAssertThrowsError(try RemindersQuery.parseListColor("chartreuse")) {
            XCTAssertEqual(($0 as? RemindersInputError)?.code, "invalid_color")
        }
        XCTAssertThrowsError(try RemindersQuery.parseListColor("#12345"))
        XCTAssertThrowsError(try RemindersQuery.parseListColor("#GGGGGG"))
    }

    // MARK: - Address strictness

    private func candidate(
        name: String? = nil,
        street: String? = "Apple Park Way",
        number: String? = "1",
        locality: String? = "Cupertino",
        postal: String? = "95014",
        radius: Double? = 60
    ) -> RemindersQuery.GeocodeCandidate {
        .init(
            name: name,
            thoroughfare: street,
            subThoroughfare: number,
            locality: locality,
            postalCode: postal,
            administrativeArea: "CA",
            country: "United States",
            latitude: 37.3349,
            longitude: -122.009,
            radiusMeters: radius
        )
    }

    private func rejection(
        _ query: String,
        _ candidates: [RemindersQuery.GeocodeCandidate]
    ) -> RemindersQuery.GeocodeRejection? {
        do {
            _ = try RemindersQuery.judgeAddress(query: query, candidates: candidates)
            return nil
        } catch let error as RemindersQuery.GeocodeRejection {
            return error
        } catch {
            return nil
        }
    }

    func testPreciseUniqueMatchIsAccepted() throws {
        let match = try RemindersQuery.judgeAddress(
            query: "1 Apple Park Way, Cupertino",
            candidates: [candidate()]
        )
        XCTAssertEqual(match.latitude, 37.3349)
        // A postal code satisfies the town requirement too.
        XCTAssertNoThrow(
            try RemindersQuery.judgeAddress(query: "1 Apple Park Way 95014", candidates: [candidate()])
        )
    }

    func testStreetAbbreviationsStillMatch() throws {
        let main = candidate(street: "Main Street", number: "10", locality: "Montpelier", postal: "05602")
        XCTAssertNoThrow(try RemindersQuery.judgeAddress(query: "10 Main St, Montpelier VT", candidates: [main]))
        let north = candidate(street: "North Main Street", number: "10", locality: "Montpelier", postal: "05602")
        XCTAssertNoThrow(try RemindersQuery.judgeAddress(query: "10 N Main St, Montpelier", candidates: [north]))
    }

    func testNoMatchAndAmbiguousMatches() {
        XCTAssertEqual(rejection("1 Nowhere Rd, Town", [])?.code, "location_not_found")
        let two = [candidate(), candidate(locality: "Elsewhere")]
        let ambiguous = rejection("1 Apple Park Way, Cupertino", two)
        XCTAssertEqual(ambiguous?.code, "location_ambiguous")
        XCTAssertEqual(ambiguous?.candidates.count, 2)
    }

    func testWholeCityIsImprecise() {
        let rome = candidate(name: "Rome", street: nil, number: nil, locality: "Rome", postal: nil, radius: 25_000)
        XCTAssertEqual(rejection("Rome", [rome])?.code, "location_imprecise")
        // Unknown radius with no street or name is imprecise as well.
        let vague = candidate(name: nil, street: nil, number: nil, radius: nil)
        XCTAssertEqual(rejection("Cupertino", [vague])?.code, "location_imprecise")
    }

    func testDifferentStreetIsUnconfirmed() {
        // "Main Street 1" resolving to some other street.
        let other = candidate(street: "Station Road", number: "1", locality: "Leeds", postal: "LS1")
        let result = rejection("1 Main Street, Leeds", [other])
        XCTAssertEqual(result?.code, "location_unconfirmed")
        XCTAssertTrue(result?.message.contains("street_mismatch") ?? false)
    }

    func testQueryWithoutTownIsUnconfirmed() {
        let result = rejection("1 Apple Park Way", [candidate()])
        XCTAssertEqual(result?.code, "location_unconfirmed")
        XCTAssertTrue(result?.message.contains("no_town") ?? false)
    }

    func testPersonalLabelsAreRefused() {
        for label in ["Home", "work", "My House", "office"] {
            XCTAssertEqual(rejection(label, [candidate()])?.code, "location_label_not_address", label)
        }
    }

    func testGeofenceRadius() throws {
        XCTAssertEqual(try RemindersQuery.validatedGeofenceRadius(nil), 100)
        XCTAssertEqual(try RemindersQuery.validatedGeofenceRadius(1), 1)
        XCTAssertEqual(try RemindersQuery.validatedGeofenceRadius(100_000), 100_000)
        XCTAssertThrowsError(try RemindersQuery.validatedGeofenceRadius(0))
        XCTAssertThrowsError(try RemindersQuery.validatedGeofenceRadius(100_001)) {
            XCTAssertEqual(($0 as? RemindersInputError)?.code, "invalid_location_radius")
        }
    }
}
