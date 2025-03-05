import AppKit
import OSLog

private let log = Logger.service("utilities")

private enum Sound: String, Hashable, CaseIterable {
    static let `default`: Sound = .sosumi

    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"
}

final class UtilitiesService: Service {
    static let shared = UtilitiesService()

    var tools: [Tool] {
        Tool(
            name: "playSystemSound",
            description: "Play a system sound. Only call if the user explicitly asks for it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sound": [
                        "type": "string",
                        "default": .string(Sound.default.rawValue),
                        "enum": .array(Sound.allCases.map { .string($0.rawValue) }),
                    ]
                ],
                "required": ["sound"],
            ]
        ) { input in
            let rawValue = input["sound"]?.stringValue ?? Sound.default.rawValue
            guard let sound = Sound(rawValue: rawValue),
                let nsSound = NSSound(named: sound.rawValue)
            else {
                log.error("Invalid sound: \(rawValue)")
                throw NSError(
                    domain: "SoundError", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Invalid sound"
                    ])
            }

            return nsSound.play()
        }
    }
}
