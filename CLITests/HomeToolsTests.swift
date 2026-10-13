import XCTest

final class HomeToolsTests: XCTestCase {
    private let backend = HomeToolRecorder()

    func testForwardingPreservesToolNameAndArguments() async throws {
        let tools = HomeTools.tools(backend: backend)
        for tool in tools {
            let arguments: [String: Value] = ["probe": .string(tool.name)]
            let value = try await tool.callAsFunction(arguments)
            XCTAssertEqual(value, .object(arguments))
        }
        let calls = await backend.names
        XCTAssertEqual(calls, tools.map(\.name))
        XCTAssertEqual(Set(calls).count, 28)
    }

    func testWriteAnnotationsAreExplicit() {
        let destructive: Set<String> = [
            "accessories_remove", "rooms_remove", "zones_remove", "scenes_remove", "automations_remove",
        ]
        let reads: Set<String> = [
            "homes_list", "home_export", "rooms_list", "zones_list", "accessories_list", "accessories_get",
            "characteristics_read", "scenes_list", "automations_list",
        ]
        for tool in HomeTools.tools(backend: backend) {
            XCTAssertEqual(tool.annotations.readOnlyHint, reads.contains(tool.name), tool.name)
            XCTAssertEqual(tool.annotations.destructiveHint, destructive.contains(tool.name), tool.name)
            XCTAssertEqual(tool.annotations.openWorldHint, false, tool.name)
        }
    }

    func testRejectsUnknownArgumentsAndWrongTypes() throws {
        XCTAssertThrowsError(try validate("rooms_create", ["name": "Test", "surprise": true]))
        XCTAssertThrowsError(try validate("home_export", ["include_values": "true"]))
        XCTAssertThrowsError(try validate("accessories_rename", ["accessory": "id"]))
        XCTAssertThrowsError(try validate("characteristics_write", ["characteristic": "id", "value": .null]))
        XCTAssertThrowsError(
            try validate("characteristics_write", ["characteristic": "id", "value": .double(.infinity)])
        )
    }

    func testTriggerKindsCannotBeMixed() throws {
        let input: [String: Value] = [
            "name": "Test", "scenes": ["scene"],
            "trigger": ["event": "sunrise", "characteristic": "id", "value": true],
        ]
        XCTAssertThrowsError(try validate("automations_create", input))
    }

    func testTimerWeekdaysAreBoundedAndUnique() throws {
        for days: Value in [[0], [8], [1, 1], [], ["Monday"]] {
            XCTAssertThrowsError(
                try validate(
                    "automations_create",
                    [
                        "name": "Test", "scenes": ["scene"],
                        "trigger": ["fire_at": "2030-01-01T12:00:00Z", "recurrence": days],
                    ]
                )
            )
        }
        try validate(
            "automations_create",
            [
                "name": "Test", "scenes": ["scene"],
                "trigger": ["fire_at": "2030-01-01T12:00:00Z", "recurrence": [2, 3, 4, 5, 6]],
            ]
        )
    }

    func testAllowsAllCharacteristicValueKindsAndTriggerVariants() throws {
        for value: Value in [true, 42, 0.5, "AQID"] {
            try validate("characteristics_write", ["characteristic": "id", "value": value])
        }
        for trigger: Value in [
            ["event": "sunrise", "offset_minutes": -30],
            ["event": "sunset"],
            ["characteristic": "id", "value": false],
            ["fire_at": "2030-01-01T12:00:00Z", "recurrence": "daily"],
        ] {
            try validate("automations_create", ["name": "Test", "scenes": ["scene"], "trigger": trigger])
        }
    }

    private func validate(_ name: String, _ input: [String: Value]) throws {
        let tool = try XCTUnwrap(HomeTools.tools(backend: backend).first { $0.name == name })
        try HomeInput.validate(input, schema: tool.inputSchema)
    }
}

private actor HomeToolRecorder: HomeBackend {
    var names: [String] = []
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        names.append(tool)
        return .object(input)
    }
}
