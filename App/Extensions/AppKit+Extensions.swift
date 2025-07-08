import AppKit

enum Sound: String, Hashable, CaseIterable {
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

extension NSSound {
    static func play(_ sound: Sound) -> Bool {
        guard let nsSound = NSSound(named: sound.rawValue) else {
            return false
        }
        return nsSound.play()
    }
}

// MARK: -

extension NSImage {
    var bitmap: NSBitmapImageRep? {
        guard let tiffData = tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiffData)
    }

    func pngData() -> Data? {
        return bitmap?.representation(using: .png, properties: [:])
    }

    func jpegData(compressionQuality: Double) -> Data? {
        return bitmap?.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: compressionQuality
            ]
        )
    }
}
