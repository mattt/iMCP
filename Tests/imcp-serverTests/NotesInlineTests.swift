import Foundation
import TopoText
import XCTest

final class NotesInlineTests: XCTestCase {
    private typealias Note = TopoText.Note

    private let source = Note.ID("0A000000-0000-0000-0000-000000000001")!
    private let target = Note.ID("0A000000-0000-0000-0000-000000000002")!

    func testKeywordsAreTagsWithTheirHash() {
        let tags = ["#groceries", "Café", "##x"].compactMap(Note.Tag.init)
        XCTAssertEqual(keywordValues(tags), ["#groceries", "#Café", "#x"])
    }

    func testUnsupportedSchemaLeavesTheReadOut() throws {
        XCTAssertEqual(try readIfSupported { 1 }, 1)
        XCTAssertNil(try readIfSupported { () throws -> Int in throw NotesError.unsupportedSchema })
    }

    func testOtherReadErrorsPropagate() {
        XCTAssertThrowsError(try readIfSupported { () throws -> Int in throw NotesError.connectionClosed }) {
            XCTAssertEqual($0 as? NotesError, .connectionClosed)
        }
        XCTAssertThrowsError(try readIfSupported { () throws -> Int in throw NotesError.timedOut }) {
            XCTAssertEqual($0 as? NotesError, .timedOut)
        }
        XCTAssertThrowsError(try readIfSupported { () throws -> Int in throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testOutgoingLinkNamesTheTargetAndKeepsDifferentLinkText() {
        let link = Note.Link(sourceID: source, targetID: target, label: "Old title")
        let object = linkValue(link, direction: .outgoing, other: .found(title: "New title")).objectValue
        XCTAssertEqual(object?["@id"], .string(target.description))
        XCTAssertEqual(object?["name"], "New title")
        XCTAssertEqual(object?["linkText"], "Old title")
        XCTAssertNil(object?["isMissing"])
    }

    func testIncomingLinkNamesTheSource() {
        let link = Note.Link(sourceID: source, targetID: target, label: "Trip")
        let object = linkValue(link, direction: .incoming, other: .found(title: "Trip")).objectValue
        XCTAssertEqual(object?["@id"], .string(source.description))
        XCTAssertEqual(object?["name"], "Trip")
        XCTAssertNil(object?["linkText"])
    }

    func testMissingTargetFallsBackToTheLabelOnlyWhenConfirmed() {
        let link = Note.Link(sourceID: source, targetID: target, label: "Gone")
        let missing = linkValue(link, direction: .outgoing, other: .missing).objectValue
        XCTAssertEqual(missing?["name"], "Gone")
        XCTAssertEqual(missing?["isMissing"], true)
        // A note that nobody found or failed to find isn't known to be missing.
        let unknown = linkValue(link, direction: .outgoing, other: .unknown).objectValue
        XCTAssertEqual(unknown?["name"], "Gone")
        XCTAssertNil(unknown?["isMissing"])
        XCTAssertNil(
            linkValue(Note.Link(sourceID: source, targetID: target), direction: .outgoing, other: .unknown)
                .objectValue?["name"]
        )
    }

    func testLookupMarksANoteMissingOnlyWhenNotesDoesNotListIt() throws {
        XCTAssertEqual(try LinkedNote(lookingUp: { "Trip" }), .found(title: "Trip"))
        XCTAssertEqual(try LinkedNote(lookingUp: { throw NotesError.noteNotFound(self.target) }), .missing)
        XCTAssertEqual(try LinkedNote(lookingUp: { throw NotesError.timedOut }), .unknown)
        XCTAssertEqual(try LinkedNote(lookingUp: { throw NotesError.databaseBusy }), .unknown)
        XCTAssertEqual(try LinkedNote(lookingUp: { throw NotesError.queryFailed("disk I/O error") }), .unknown)
    }

    func testLookupPropagatesCancellationAndAClosedConnection() {
        XCTAssertThrowsError(try LinkedNote(lookingUp: { throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try LinkedNote(lookingUp: { throw NotesError.connectionClosed })) {
            XCTAssertEqual($0 as? NotesError, .connectionClosed)
        }
    }

    func testSmartFolderQueryStripsTheDeletedClause() {
        let query = SmartFolderQuery(#"{"entity":"note","type":{"and":[{"deleted":false},{"pinned":true}]}}"#)
        XCTAssertEqual(query.rules, ["pinned": true])
        XCTAssertEqual(query.includesRecentlyDeleted, false)
    }

    func testSmartFolderQueryKeepsSeveralRulesTogether() {
        let query = SmartFolderQuery(#"{"type":{"and":[{"deleted":true},{"tag":"A"},{"attachment":true}]}}"#)
        XCTAssertEqual(query.rules, ["and": [["tag": "A"], ["attachment": true]]])
        XCTAssertEqual(query.includesRecentlyDeleted, true)
    }

    func testSmartFolderQueryKeepsWhatItDoesNotKnow() {
        XCTAssertEqual(SmartFolderQuery(#"{"tags":["groceries"]}"#).rules, ["tags": ["groceries"]])
        XCTAssertEqual(SmartFolderQuery(#"{"type":{"or":[{"pinned":true}]}}"#).rules, ["or": [["pinned": true]]])
        XCTAssertNil(SmartFolderQuery("not json").rules)
        XCTAssertNil(SmartFolderQuery("not json").includesRecentlyDeleted)
    }

    func testSmartFolderQueryReducesTheObservedTagRule() {
        let text =
            #"{"type":{"and":[{"deleted":false},{"and":[{"and":[{"deleted":false},{"and":[{"tag":"SMART"}]}]}]}]},"entity":"note"}"#
        let query = SmartFolderQuery(text)
        XCTAssertEqual(query.rules, ["tag": "SMART"])
        XCTAssertEqual(query.includesRecentlyDeleted, false)
    }

    func testSmartFolderQueryKeepsTwoRulesInTheirConjunction() {
        let query = SmartFolderQuery(
            #"{"type":{"and":[{"deleted":false},{"and":[{"and":[{"deleted":false},{"and":[{"tag":"A"},{"pinned":true}]}]}]}]}}"#
        )
        XCTAssertEqual(query.rules, ["and": [["tag": "A"], ["pinned": true]]])
        XCTAssertEqual(query.includesRecentlyDeleted, false)
    }

    func testSmartFolderQueryLeavesOrClausesAsStored() {
        let query = SmartFolderQuery(
            #"{"type":{"and":[{"deleted":false},{"or":[{"and":[{"tag":"A"}]},{"deleted":true}]}]}}"#
        )
        XCTAssertEqual(query.rules, ["or": [["and": [["tag": "A"]]], ["deleted": true]]])
        XCTAssertEqual(query.includesRecentlyDeleted, false)
    }

    func testSmartFolderQueryKeepsDisagreeingDeletedClausesAsStored() {
        let nested = SmartFolderQuery(
            #"{"type":{"and":[{"deleted":false},{"and":[{"deleted":true},{"and":[{"tag":"A"}]}]}]}}"#
        )
        XCTAssertEqual(
            nested.rules,
            ["and": [["deleted": false], ["and": [["deleted": true], ["and": [["tag": "A"]]]]]]]
        )
        XCTAssertNil(nested.includesRecentlyDeleted)

        let flat = SmartFolderQuery(#"{"type":{"and":[{"deleted":false},{"deleted":true},{"tag":"A"}]}}"#)
        XCTAssertEqual(flat.rules, ["and": [["deleted": false], ["deleted": true], ["tag": "A"]]])
        XCTAssertNil(flat.includesRecentlyDeleted)
    }

    func testSmartFolderQueryKeepsOtherShapesWhole() {
        XCTAssertEqual(SmartFolderQuery(#"{"type":["pinned"]}"#).rules, ["pinned"])
        XCTAssertEqual(SmartFolderQuery(#"[{"and":[{"tag":"A"}]}]"#).rules, [["and": [["tag": "A"]]]])
        XCTAssertNil(SmartFolderQuery(#"{"tags":["groceries"]}"#).includesRecentlyDeleted)
    }

    func testSmartFolderValueHasRulesParentAndStoredQuery() {
        let parent = TopoText.Folder.ID("P")!
        let text = #"{"type":{"and":[{"deleted":false},{"pinned":true}]}}"#
        let folder = TopoText.SmartFolder(
            id: TopoText.SmartFolder.ID("S")!,
            name: "Pinned",
            parentID: parent,
            query: text
        )
        let object = smartFolderValue(folder, folderNames: [parent: "Recipes"]).objectValue
        XCTAssertEqual(object?["@id"], "S")
        XCTAssertEqual(object?["name"], "Pinned")
        XCTAssertNil(object?["account"])
        XCTAssertEqual(object?["parentFolder"], ["@id": "P", "name": "Recipes"])
        XCTAssertEqual(object?["rules"], ["pinned": true])
        XCTAssertEqual(object?["query"], .string(text))
        XCTAssertNil(object?["includesRecentlyDeleted"])
    }
}
