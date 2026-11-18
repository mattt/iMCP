import XCTest

/// Checks which items the menu bar panel has and how they group.
final class MenuStructureTests: XCTestCase {
    private let services = [
        MenuServiceItem(id: "A", name: "Calendar", symbol: "calendar", isOn: true),
        MenuServiceItem(id: "B", name: "Mail", symbol: "envelope.fill", isOn: false),
    ]

    func testGroupsAreServerServicesActivityClientsAppAndQuit() {
        let sections = MenuStructure.make(isServerEnabled: true, services: services)
        XCTAssertEqual(sections.count, 6)
        XCTAssertEqual(sections[0], .server(isOn: true))
        XCTAssertEqual(sections[1], .services(items: services))
        XCTAssertEqual(sections[2], .activity)
        XCTAssertEqual(sections[3], .actions([.configureClaudeDesktop, .copyServerCommand]))
        XCTAssertEqual(sections[4], .actions([.settings, .checkForUpdates, .about]))
        XCTAssertEqual(sections[5], .actions([.quit]))
    }

    func testServicesAreHiddenWhileServerIsOff() {
        let sections = MenuStructure.make(isServerEnabled: false, services: services)
        XCTAssertEqual(sections.count, 5)
        XCTAssertEqual(sections[0], .server(isOn: false))
        XCTAssertEqual(sections[1], .activity, "activity stays reachable while the server is off")
        XCTAssertFalse(sections.contains { if case .services = $0 { true } else { false } })
    }

    func testEveryActionAppearsOnceAndHasATitle() {
        let sections = MenuStructure.make(isServerEnabled: true, services: services)
        let actions = sections.flatMap { section -> [MenuAction] in
            if case .actions(let actions) = section { return actions }
            return []
        }
        XCTAssertEqual(Set(actions), Set(MenuAction.allCases))
        XCTAssertEqual(actions.count, MenuAction.allCases.count)
        XCTAssertTrue(MenuAction.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
