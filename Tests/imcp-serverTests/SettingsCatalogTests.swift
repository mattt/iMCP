import XCTest

final class SettingsCatalogTests: XCTestCase {
    func testEveryTabHasSettings() {
        for tab in SettingsPane.tabs {
            XCTAssertFalse(SettingsItem.items(in: tab).isEmpty, "\(tab.title) has no settings")
        }
    }

    func testSettingsLiveWhereAPersonWouldLookForThem() {
        XCTAssertEqual(SettingsItem.approvalMode.tab, .general)
        XCTAssertEqual(SettingsItem.trustedApps.tab, .clients)
        XCTAssertEqual(SettingsItem.connectedCloudApps.tab, .clients)
        XCTAssertEqual(SettingsItem.routeList.tab, .mobile)
        XCTAssertEqual(SettingsItem.accessChoice.tab, .remoteAccess)
        XCTAssertEqual(SettingsItem.accessTokens.tab, .advanced)
        XCTAssertEqual(SettingsItem.mobileOverrides.tab, .advanced)
        XCTAssertEqual(SettingsItem.serverCommand.tab, .advanced)
        XCTAssertEqual(SettingsItem.cachedData.tab, .advanced)
    }

    /// Settings stores the raw value to reopen to the same tab, so these must not change.
    func testStoredTabValuesAreStable() {
        XCTAssertEqual(SettingsPane.general.rawValue, "general")
        XCTAssertEqual(SettingsPane.clients.rawValue, "clients")
        XCTAssertEqual(SettingsPane.mobile.rawValue, "mobile")
        XCTAssertEqual(SettingsPane.remoteAccess.rawValue, "remoteAccess")
        XCTAssertEqual(SettingsPane.advanced.rawValue, "advanced")
    }

    /// A stored service id reopens to that service's pane.
    func testStoredServiceIDsReopenToTheService() {
        XCTAssertEqual(SettingsPane(rawValue: "CalendarService"), .service("CalendarService"))
        XCTAssertEqual(SettingsPane.service("NotesService").rawValue, "NotesService")
    }

    func testEveryApprovalModeHasAShortCaption() {
        for mode in ApprovalMode.allCases {
            XCTAssertFalse(mode.settingsCaption.isEmpty)
            XCTAssertLessThanOrEqual(mode.settingsCaption.count, 60)
        }
    }
}
