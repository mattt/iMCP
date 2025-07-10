import AVFoundation

// MARK: - Capture Device Types

enum CaptureDeviceType: String, Hashable, CaseIterable {
    static let `default`: CaptureDeviceType = .builtInWideAngle

    case builtInWideAngle = "built-in"
    case continuity = "continuity"
    case external = "external"
    case deskView = "desk-view"

    var avDeviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .builtInWideAngle:
            return .builtInWideAngleCamera
        case .continuity:
            return .continuityCamera
        case .deskView:
            return .deskViewCamera
        case .external:
            return .external
        }
    }
}

// MARK: - Capture Device Position

enum CaptureDevicePosition: String, Hashable, CaseIterable {
    static let `default`: CaptureDevicePosition = .unspecified

    case unspecified = "unspecified"
    case back = "back"
    case front = "front"

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .unspecified:
            return .unspecified
        case .back:
            return .back
        case .front:
            return .front
        }
    }
}

// MARK: - Flash Mode

enum FlashMode: String, Hashable, CaseIterable {
    static let `default`: FlashMode = .auto

    case auto = "auto"
    case on = "on"
    case off = "off"

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto:
            return .auto
        case .on:
            return .on
        case .off:
            return .off
        }
    }
}

// MARK: - Session Preset

enum SessionPreset: String, Hashable, CaseIterable {
    static let `default`: SessionPreset = .photo

    case photo = "photo"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case hd1280x720 = "hd1280x720"
    case hd1920x1080 = "hd1920x1080"
    case hd4K3840x2160 = "hd4K3840x2160"

    var avPreset: AVCaptureSession.Preset {
        switch self {
        case .photo:
            return .photo
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .hd1280x720:
            return .hd1280x720
        case .hd1920x1080:
            return .hd1920x1080
        case .hd4K3840x2160:
            return .hd4K3840x2160
        }
    }
}

// MARK: - Image Format

enum ImageFormat: String, Hashable, CaseIterable {
    static let `default`: ImageFormat = .jpeg

    case jpeg = "jpeg"
    case png = "png"

    var mimeType: String {
        switch self {
        case .jpeg:
            return "image/jpeg"
        case .png:
            return "image/png"
        }
    }
}

// MARK: - Audio Format

enum AudioFormat: String, Hashable, CaseIterable {
    static let `default`: AudioFormat = .mp4

    case mp4 = "mp4"
    case caf = "caf"

    var fileExtension: String {
        return rawValue
    }

    var mimeType: String {
        switch self {
        case .mp4:
            return "audio/mp4"
        case .caf:
            return "audio/x-caf"
        }
    }
}

// MARK: - AVCaptureDevice Extensions

extension AVCaptureDevice {
    static func device(
        for deviceType: CaptureDeviceType,
        position: CaptureDevicePosition,
        mediaType: AVMediaType
    ) -> AVCaptureDevice? {
        if position == .unspecified {
            return AVCaptureDevice.default(for: mediaType)
        }

        if let device = AVCaptureDevice.default(
            deviceType.avDeviceType,
            for: mediaType,
            position: position.avPosition
        ) {
            return device
        }

        // Fallback to built-in camera with specified position
        return AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: mediaType,
            position: position.avPosition
        )
    }
}
