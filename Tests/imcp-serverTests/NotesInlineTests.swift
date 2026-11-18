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

    func testOutgoingLinkNamesTheTargetAndKeepsDifferentLinkText() {
        let link = Note.Link(sourceID: source, targetID: target, label: "Old title")
        let object = linkValue(link, direction: .outgoing, otherTitle: "New title").objectValue
        XCTAssertEqual(object?["@id"], .string(target.description))
        XCTAssertEqual(object?["name"], "New title")
        XCTAssertEqual(object?["linkText"], "Old title")
        XCTAssertNil(object?["isMissing"])
    }

    func testIncomingLinkNamesTheSource() {
        let link = Note.Link(sourceID: source, targetID: target, label: "Trip")
        let object = linkValue(link, direction: .incoming, otherTitle: "Trip").objectValue
        XCTAssertEqual(object?["@id"], .string(source.description))
        XCTAssertEqual(object?["name"], "Trip")
        XCTAssertNil(object?["linkText"])
    }

    func testMissingTargetFallsBackToTheLabelOnlyWhenLookedUp() {
        let link = Note.Link(sourceID: source, targetID: target, label: "Gone")
        let checked = linkValue(link, direction: .outgoing, otherTitle: nil).objectValue
        XCTAssertEqual(checked?["name"], "Gone")
        XCTAssertEqual(checked?["isMissing"], true)
        // A caller that didn't look up the target can't say it is missing.
        let unchecked = linkValue(link, direction: .outgoing, otherTitle: nil, wasLookedUp: false).objectValue
        XCTAssertNil(unchecked?["isMissing"])
        XCTAssertNil(
            linkValue(
                Note.Link(sourceID: source, targetID: target),
                direction: .outgoing,
                otherTitle: nil,
                wasLookedUp: false
            ).objectValue?["name"]
        )
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
