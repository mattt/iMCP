import JSONSchema

/// Tool definitions shared by the native proxy and the Catalyst helper.
enum HomeTools {
    static let identifier = JSONSchema.string(description: "HomeKit uniqueIdentifier UUID")
    static let identifiers = JSONSchema.array(items: identifier)
    static let value = JSONSchema.anyOf([.boolean(), .number(), .string()])
    static let actions = JSONSchema.array(
        items: .object(
            properties: ["characteristic": identifier, "value": value],
            required: ["characteristic", "value"],
            additionalProperties: false
        )
    )
    static let trigger = JSONSchema.anyOf([
        .object(
            properties: [
                "fire_at": .string(
                    description: "Future ISO 8601 timestamp on a whole-minute boundary, with a time zone.",
                    format: .dateTime
                ),
                "recurrence": .anyOf([
                    .string(enum: ["daily"]),
                    .array(items: .integer(minimum: 1, maximum: 7), minItems: 1, uniqueItems: true),
                ]),
            ],
            required: ["fire_at"],
            additionalProperties: false
        ),
        .object(
            properties: ["characteristic": identifier, "value": value],
            required: ["characteristic", "value"],
            additionalProperties: false
        ),
        .object(
            properties: [
                "event": .string(enum: ["sunrise", "sunset"]),
                "offset_minutes": .integer(),
            ],
            required: ["event"],
            additionalProperties: false
        ),
    ])

    static func tools(backend: any HomeBackend) -> [Tool] {
        let home: [String: JSONSchema] = [
            "home": .string(description: "Home UUID. Required when more than one home exists.")
        ]
        let includeValues = JSONSchema.boolean(
            description: "Read live values. Defaults to false; unreachable devices return per-item errors.",
            default: false
        )
        func tool(
            _ name: String,
            _ description: String,
            _ properties: [String: JSONSchema] = [:],
            required: [String] = [],
            read: Bool = false,
            idempotent: Bool = false,
            destructive: Bool = false
        ) -> Tool {
            Tool(
                name: name,
                description: description,
                inputSchema: .object(
                    properties: .init(uniqueKeysWithValues: properties.sorted { $0.key < $1.key }),
                    required: required,
                    additionalProperties: false
                ),
                annotations: .init(
                    readOnlyHint: read,
                    destructiveHint: destructive,
                    idempotentHint: read || idempotent,
                    openWorldHint: false
                )
            ) { input in
                try await backend.call(name, input)
            }
        }
        func withHome(_ properties: [String: JSONSchema]) -> [String: JSONSchema] {
            home.merging(properties) { _, value in value }
        }
        return [
            tool("homes_list", "List homes, counts, primary home, and authorization status.", read: true),
            tool(
                "home_export",
                "Export rooms, zones, accessories, services, characteristic metadata, scenes, and exposed automations.",
                withHome(["include_values": includeValues]),
                read: true
            ),
            tool("rooms_list", "List rooms and identify the Default Room.", home, read: true),
            tool("zones_list", "List zones and their room IDs.", home, read: true),
            tool(
                "accessories_list",
                "List accessories with room, bridge, reachability, and service information.",
                withHome([
                    "room": identifier, "category": .string(), "reachable": .boolean(),
                    "bridged": .boolean(), "in_default_room": .boolean(), "name_contains": .string(),
                ]),
                read: true
            ),
            tool(
                "accessories_get",
                "Inspect an accessory and its characteristics.",
                ["accessory": identifier, "include_values": includeValues],
                required: ["accessory"],
                read: true
            ),
            tool(
                "characteristics_read",
                "Read live characteristic values with one result per UUID.",
                ["characteristics": identifiers],
                required: ["characteristics"],
                read: true
            ),
            tool("scenes_list", "List scenes with resolved characteristic actions.", home, read: true),
            tool(
                "automations_list",
                "List automation data exposed by HomeKit. Shortcuts and some Home app conditions may be incomplete. lastFireDate is unavailable.",
                home,
                read: true
            ),
            tool(
                "accessories_identify",
                "Ask an accessory to identify itself with a light or sound.",
                ["accessory": identifier],
                required: ["accessory"],
                idempotent: true
            ),
            tool(
                "accessories_rename",
                "Rename an accessory.",
                ["accessory": identifier, "name": .string()],
                required: ["accessory", "name"],
                idempotent: true
            ),
            tool(
                "services_rename",
                "Rename a service within an accessory.",
                ["service": identifier, "name": .string()],
                required: ["service", "name"],
                idempotent: true
            ),
            tool(
                "accessories_assign_room",
                "Move accessories to a room. Return one result per accessory.",
                ["room": identifier, "accessories": identifiers],
                required: ["room", "accessories"],
                idempotent: true
            ),
            tool(
                "accessories_remove",
                "Remove an accessory from its home. Pairing is required to add it again.",
                ["accessory": identifier],
                required: ["accessory"],
                destructive: true
            ),
            tool("rooms_create", "Create a room.", withHome(["name": .string()]), required: ["name"]),
            tool(
                "rooms_rename",
                "Rename a room.",
                ["room": identifier, "name": .string()],
                required: ["room", "name"],
                idempotent: true
            ),
            tool(
                "rooms_remove",
                "Remove a room. Its accessories return to the Default Room.",
                ["room": identifier],
                required: ["room"],
                destructive: true
            ),
            tool(
                "zones_create",
                "Create a zone with optional rooms.",
                withHome(["name": .string(), "rooms": identifiers]),
                required: ["name"]
            ),
            tool(
                "zones_update",
                "Rename a zone or change its rooms.",
                ["zone": identifier, "name": .string(), "add_rooms": identifiers, "remove_rooms": identifiers],
                required: ["zone"],
                idempotent: true
            ),
            tool(
                "zones_remove",
                "Remove a zone without removing its rooms.",
                ["zone": identifier],
                required: ["zone"],
                destructive: true
            ),
            tool(
                "characteristics_write",
                "Write a characteristic value after checking its format and limits. Data values use base64 strings.",
                ["characteristic": identifier, "value": value],
                required: ["characteristic", "value"],
                idempotent: true
            ),
            tool(
                "scenes_create",
                "Create a scene with characteristic write actions.",
                withHome(["name": .string(), "actions": actions]),
                required: ["name", "actions"]
            ),
            tool(
                "scenes_update",
                "Rename a scene, set characteristic actions, or remove actions.",
                [
                    "scene": identifier, "name": .string(), "add_actions": actions,
                    "remove_characteristics": identifiers,
                ],
                required: ["scene"],
                idempotent: true
            ),
            tool(
                "scenes_execute",
                "Execute a scene and change its devices.",
                ["scene": identifier],
                required: ["scene"]
            ),
            tool(
                "scenes_remove",
                "Remove a scene from the home.",
                ["scene": identifier],
                required: ["scene"],
                destructive: true
            ),
            tool(
                "automations_update",
                "Rename an automation or change whether it is enabled.",
                ["automation": identifier, "name": .string(), "enabled": .boolean()],
                required: ["automation"],
                idempotent: true
            ),
            tool(
                "automations_remove",
                "Remove an automation from the home.",
                ["automation": identifier],
                required: ["automation"],
                destructive: true
            ),
            tool(
                "automations_create",
                "Create an enabled automation for a timer, characteristic value, sunrise, or sunset. Timer recurrence is daily or weekday numbers (1 Sunday through 7 Saturday).",
                withHome(["name": .string(), "scenes": identifiers, "trigger": trigger]),
                required: ["name", "scenes", "trigger"]
            ),
        ]
    }
}
