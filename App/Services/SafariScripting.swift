import Foundation

// The Reading List tool of the Safari service, and what it checks.
//
// Safari's scripting interface can add to the Reading List,
// and it has no command that reads or changes bookmarks.
// This file holds the logic that needs no Safari, so that tests can cover it.

/// A request that the Safari service refuses, and the reason.
enum SafariError: LocalizedError, CustomStringConvertible, Equatable {
    case invalid(String)
    case notRunning
    case automationDenied
    case scriptFailed(String)
    case noExport
    case exportUnreadable(String)

    var description: String { localizedDescription }

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "Invalid argument: \(message)"
        case .notRunning:
            return "Safari isn't open. iMCP doesn't start it. Open Safari and try again."
        case .automationDenied:
            return
                "Not authorized to send Apple events to Safari. Enable iMCP in System Settings > Privacy & Security > Automation."
        case .scriptFailed(let message):
            return "Safari could not complete the request: \(message)"
        case .noExport:
            return
                "iMCP has no exported bookmarks file. In Safari, choose File > Export > Bookmarks and save the file. Then switch the Safari service off and on in iMCP, and choose that file."
        case .exportUnreadable(let reason):
            return
                "The exported bookmarks file can't be read: \(reason). Export the bookmarks again from Safari, then switch the Safari service off and on in iMCP and choose the file."
        }
    }
}

/// A web address to add to the Reading List, once checked.
struct SafariReadingListItem: Equatable, Sendable {
    static let maximumURLLength = 2_048
    static let maximumTitleLength = 500
    static let maximumPreviewLength = 2_000

    let url: String
    let title: String
    let previewText: String

    /// Checks the arguments of `safari_reading_list_add`.
    ///
    /// Only `http` and `https` addresses are added:
    /// the Reading List holds web pages, and other schemes could name files or run script.
    init(url: String, title: String?, previewText: String?) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw SafariError.invalid("url can't be empty") }
        guard url.count <= Self.maximumURLLength else {
            throw SafariError.invalid("url can have at most \(Self.maximumURLLength) characters")
        }
        guard let components = URLComponents(string: url),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else {
            throw SafariError.invalid("url must be a web address that starts with http:// or https://")
        }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.count <= Self.maximumTitleLength else {
            throw SafariError.invalid("title can have at most \(Self.maximumTitleLength) characters")
        }
        let preview = previewText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard preview.count <= Self.maximumPreviewLength else {
            throw SafariError.invalid("previewText can have at most \(Self.maximumPreviewLength) characters")
        }
        self.url = url
        self.title = title
        self.previewText = preview
    }
}

enum SafariScripts {
    static let bundleID = "com.apple.Safari"

    /// A fixed script. The address, title, and preview reach it as arguments, never as source text.
    static let source = """
        on addreadinglistitem(theURL, theTitle, thePreview)
            tell application id "\(bundleID)"
                if theTitle is "" and thePreview is "" then
                    add reading list item theURL
                else if thePreview is "" then
                    add reading list item theURL with title theTitle
                else if theTitle is "" then
                    add reading list item theURL and preview text thePreview
                else
                    add reading list item theURL and preview text thePreview with title theTitle
                end if
                return true
            end tell
        end addreadinglistitem
        """

    static func addReadingListItem(_ item: SafariReadingListItem) -> NSAppleScript.Subroutine {
        .init("addreadinglistitem", [.string(item.url), .string(item.title), .string(item.previewText)])
    }
}

/// The dates that the bookmark search accepts.
enum SafariDates {
    /// Reads an ISO 8601 date or date and time, or a date alone, which means midnight in the local time zone.
    static func parse(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = .current
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: text)
    }
}
