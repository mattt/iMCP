import AppKit
import AudioToolbox

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
        // Attempt to play via AudioServices (system alert sound)
        if let url = Self.urlForSystemSound(named: sound.rawValue),
            let systemSoundID = Self.systemSoundID(for: url)
        {
            AudioServicesPlayAlertSound(systemSoundID)
            return true
        }

        // Fallback to NSSound by name if URL resolution failed
        guard let nsSound = NSSound(named: sound.rawValue) else {
            return false
        }
        return nsSound.play()
    }

    // MARK: - Private helpers

    private static var soundIDCache: [URL: SystemSoundID] = [:]

    private static func systemSoundID(for url: URL) -> SystemSoundID? {
        if let cached = soundIDCache[url] {
            return cached
        }
        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else {
            return nil
        }
        soundIDCache[url] = soundID
        return soundID
    }

    private static func urlForSystemSound(named name: String) -> URL? {
        let fileExtensions = ["aiff", "caf", "wav", "mp3", "m4a"]
        let searchDirectories: [URL] = [
            URL(
                fileURLWithPath: ("~/Library/Sounds" as NSString).expandingTildeInPath,
                isDirectory: true),
            URL(fileURLWithPath: "/Library/Sounds", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
        ]

        let fileManager = FileManager.default
        for directory in searchDirectories {
            for ext in fileExtensions {
                let candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
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
