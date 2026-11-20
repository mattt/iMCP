import Foundation
import OSLog

private let log = Logger.service("calendar")

/// A calendar as the selection sees it: an identifier and a title.
protocol CalendarSelectable {
    var selectionIdentifier: String { get }
    var selectionTitle: String { get }
}

/// Which calendars iMCP exposes to clients.
///
/// By default, iMCP exposes every calendar, including calendars added later.
/// Turning off "Show new calendars automatically" in Settings
/// hides calendars that iMCP hasn't seen before until someone selects them.
/// Calendars are tracked by identifier,
/// so renaming a calendar or an account losing a calendar for a while
/// doesn't change the choices for the others.
struct CalendarSelection: Codable, Equatable {
    /// Whether a calendar that isn't in `selected` or `deselected` is shown.
    var showsNewCalendars = true
    private(set) var selected: Set<String> = []
    private(set) var deselected: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case showsNewCalendars
        case selected
        case deselected
    }

    init(
        showsNewCalendars: Bool = true,
        selected: Set<String> = [],
        deselected: Set<String> = []
    ) {
        self.showsNewCalendars = showsNewCalendars
        self.selected = selected
        self.deselected = deselected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsNewCalendars =
            try container.decodeIfPresent(Bool.self, forKey: .showsNewCalendars) ?? true
        selected = try container.decodeIfPresent(Set<String>.self, forKey: .selected) ?? []
        deselected = try container.decodeIfPresent(Set<String>.self, forKey: .deselected) ?? []
    }

    func isSelected(_ identifier: String) -> Bool {
        if selected.contains(identifier) { return true }
        if deselected.contains(identifier) { return false }
        return showsNewCalendars
    }

    mutating func setSelected(_ isSelected: Bool, for identifier: String) {
        if isSelected {
            selected.insert(identifier)
            deselected.remove(identifier)
        } else {
            deselected.insert(identifier)
            selected.remove(identifier)
        }
    }

    /// Changes whether new calendars are shown,
    /// keeping every calendar in `identifiers` as it is now.
    mutating func setShowsNewCalendars(_ shows: Bool, existing identifiers: [String]) {
        for identifier in identifiers {
            setSelected(isSelected(identifier), for: identifier)
        }
        showsNewCalendars = shows
    }

    func filter<Calendar: CalendarSelectable>(_ calendars: [Calendar]) -> [Calendar] {
        calendars.filter { isSelected($0.selectionIdentifier) }
    }

    /// The calendars named in a request, matched case-insensitively.
    ///
    /// A name that matches a selected calendar resolves to it.
    /// A name that matches only calendars that aren't selected is an error,
    /// so a client learns why instead of getting no results.
    /// A name that matches no calendar at all resolves to nothing.
    func resolve<Calendar: CalendarSelectable>(
        names: [String],
        in calendars: [Calendar]
    ) throws -> [Calendar] {
        var resolved: [Calendar] = []
        for name in names {
            let matches = calendars.filter {
                $0.selectionTitle.lowercased() == name.lowercased()
            }
            let selectedMatches = matches.filter { isSelected($0.selectionIdentifier) }
            if selectedMatches.isEmpty, !matches.isEmpty {
                throw CalendarSelectionError.notShared(name)
            }
            resolved.append(contentsOf: selectedMatches)
        }
        return resolved
    }

    /// Throws unless the calendar is selected.
    func require<Calendar: CalendarSelectable>(_ calendar: Calendar) throws {
        guard isSelected(calendar.selectionIdentifier) else {
            throw CalendarSelectionError.notShared(calendar.selectionTitle)
        }
    }
}

enum CalendarSelectionError: LocalizedError, Equatable {
    case notShared(String)

    var errorDescription: String? {
        switch self {
        case .notShared(let title):
            return
                "The calendar \"\(title)\" isn't shared with iMCP. "
                + "The person using iMCP can choose calendars in Settings, under Calendar."
        }
    }
}

/// Keeps the selection in `UserDefaults`.
struct CalendarSelectionStore {
    static let key = "calendarSelection"

    var defaults: UserDefaults = .standard

    var selection: CalendarSelection {
        get {
            guard let data = defaults.data(forKey: Self.key) else {
                return CalendarSelection()
            }
            do {
                return try JSONDecoder().decode(CalendarSelection.self, from: data)
            } catch {
                log.error(
                    "Failed to decode calendar selection; sharing no calendars until updated: \(error.localizedDescription, privacy: .public)"
                )
                return CalendarSelection(showsNewCalendars: false)
            }
        }
        nonmutating set {
            do {
                defaults.set(try JSONEncoder().encode(newValue), forKey: Self.key)
            } catch {
                log.error(
                    "Failed to encode calendar selection: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
