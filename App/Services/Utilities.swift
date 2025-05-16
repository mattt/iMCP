import AppKit
import JSONSchema
import OSLog

private let log = Logger.service("utilities")

final class UtilitiesService: Service {
    static let shared = UtilitiesService()

    var tools: [Tool] {
        Tool(
            name: "utilities_beep",
            description: "Play a system sound",
            inputSchema: .object(
                properties: [
                    "sound": .string(
                        default: .string(Sound.default.rawValue),
                        enum: Sound.allCases.map { .string($0.rawValue) })
                ],
                required: ["sound"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Play System Sound",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { input in
            let rawValue = input["sound"]?.stringValue ?? Sound.default.rawValue
            guard let sound = Sound(rawValue: rawValue) else {
                log.error("Invalid sound: \(rawValue)")
                throw NSError(
                    domain: "SoundError", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Invalid sound"
                    ])
            }

            return NSSound.play(sound)
        }
    }
}
