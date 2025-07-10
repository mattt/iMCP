import AVFoundation
import AppKit
import Foundation
import OSLog
import ObjectiveC
import Ontology
import ScreenCaptureKit
import SwiftUI

private let log = Logger.service("capture")

final class CaptureService: NSObject, Service {
    static let shared = CaptureService()

    private var captureSession: AVCaptureSession?
    private var audioRecorder: AVAudioRecorder?
    private var photoOutput: AVCapturePhotoOutput?
    private var currentPhotoDelegate: PhotoCaptureDelegate?

    override init() {
        super.init()
        log.debug("Initializing capture service")
    }

    deinit {
        log.info("Deinitializing capture service")
        captureSession?.stopRunning()
        audioRecorder?.stop()
    }

    var isActivated: Bool {
        get async {
            let cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            let microphoneAuthorized =
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
            return cameraAuthorized || microphoneAuthorized || screenRecordingAuthorized
        }
    }

    func activate() async throws {
        try await requestPermission(for: .video)
        try await requestPermission(for: .audio)
        try await requestScreenRecordingPermission()
    }

    private func requestPermission(for mediaType: AVMediaType) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        let mediaName = mediaType == .video ? "Camera" : "Microphone"

        switch status {
        case .authorized:
            log.debug("\(mediaName) access already authorized")
            return
        case .denied, .restricted:
            log.error("\(mediaName) access denied")
            throw NSError(
                domain: "CaptureServiceError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(mediaName) access denied"]
            )
        case .notDetermined:
            log.debug("Requesting \(mediaName) access")
            let granted = await AVCaptureDevice.requestAccess(for: mediaType)
            if !granted {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(mediaName) access denied"]
                )
            }
        @unknown default:
            log.error("Unknown \(mediaName) authorization status")
            throw NSError(
                domain: "CaptureServiceError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown authorization status"]
            )
        }
    }

    private func requestScreenRecordingPermission() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            // Request screen recording access
            guard CGRequestScreenCaptureAccess() else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Screen recording access denied"]
                )
            }
            return
        }
    }

    var tools: [Tool] {
        Tool(
            name: "capture_take_picture",
            description: "Take a picture with the device camera",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        default: .string(ImageFormat.default.rawValue),
                        enum: ImageFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "quality": .number(
                        description: "JPEG quality",
                        default: 0.8,
                        minimum: 0.0,
                        maximum: 1.0
                    ),
                    "preset": .string(
                        description: "Camera quality preset",
                        default: .string(SessionPreset.default.rawValue),
                        enum: SessionPreset.allCases.map { .string($0.rawValue) }
                    ),
                    "device": .string(
                        description: "Camera device type",
                        default: .string(CaptureDeviceType.default.rawValue),
                        enum: CaptureDeviceType.allCases.map { .string($0.rawValue) }
                    ),
                    "position": .string(
                        description: "Camera position",
                        default: .string(CaptureDevicePosition.default.rawValue),
                        enum: CaptureDevicePosition.allCases.map { .string($0.rawValue) }
                    ),
                    "flash": .string(
                        description: "Flash mode",
                        default: .string(FlashMode.default.rawValue),
                        enum: FlashMode.allCases.map { .string($0.rawValue) }
                    ),
                    "autoExposure": .boolean(
                        description: "Enable automatic exposure and light balancing",
                        default: true
                    ),
                    "autoFocus": .boolean(
                        description: "Enable automatic focus",
                        default: true
                    ),
                    "autoWhiteBalance": .boolean(
                        description: "Enable automatic white balance",
                        default: true
                    ),
                    "delay": .number(
                        description: "Delay before taking photo, in seconds",
                        default: 1,
                        minimum: 0,
                        maximum: 60
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Take Picture",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard await self.isActivated else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Camera access not authorized"]
                )
            }

            let format =
                ImageFormat(
                    rawValue: arguments["format"]?.stringValue ?? ImageFormat.default.rawValue)
                ?? .jpeg
            let quality = arguments["quality"]?.doubleValue ?? 0.8
            let preset =
                SessionPreset(
                    rawValue: arguments["preset"]?.stringValue ?? SessionPreset.default.rawValue)
                ?? .photo
            let device =
                CaptureDeviceType(
                    rawValue: arguments["device"]?.stringValue ?? CaptureDeviceType.default.rawValue
                )
                ?? .builtInWideAngle
            let position =
                CaptureDevicePosition(
                    rawValue: arguments["position"]?.stringValue
                        ?? CaptureDevicePosition.default.rawValue) ?? .unspecified
            let flash =
                FlashMode(rawValue: arguments["flash"]?.stringValue ?? FlashMode.default.rawValue)
                ?? .auto
            let autoExposure = arguments["autoExposure"]?.boolValue ?? true
            let autoFocus = arguments["autoFocus"]?.boolValue ?? true
            let autoWhiteBalance = arguments["autoWhiteBalance"]?.boolValue ?? true
            let delay = arguments["delay"]?.doubleValue ?? 1.0

            let captureSession = AVCaptureSession()
            captureSession.sessionPreset = preset.avPreset

            guard
                let camera = AVCaptureDevice.device(
                    for: device,
                    position: position,
                    mediaType: .video
                )
            else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "No camera device found"]
                )
            }

            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            if autoExposure && camera.isExposureModeSupported(.autoExpose) {
                camera.exposureMode = .autoExpose
            }

            if autoFocus && camera.isFocusModeSupported(.autoFocus) {
                camera.focusMode = .autoFocus
            }

            if autoWhiteBalance && camera.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                camera.whiteBalanceMode = .autoWhiteBalance
            }

            let videoInput = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(videoInput) else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"]
                )
            }
            captureSession.addInput(videoInput)

            let photoOutput = AVCapturePhotoOutput()
            guard captureSession.canAddOutput(photoOutput) else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add photo output"]
                )
            }
            captureSession.addOutput(photoOutput)

            return try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false
                let resumeOnce = { (result: Result<Value, Error>) in
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(with: result)
                }

                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(10))
                    if !hasResumed {
                        await MainActor.run {
                            captureSession.stopRunning()
                            self.currentPhotoDelegate = nil
                        }
                        resumeOnce(
                            .failure(
                                NSError(
                                    domain: "CaptureServiceError",
                                    code: 9,
                                    userInfo: [NSLocalizedDescriptionKey: "Camera capture timeout"]
                                )))
                    }
                }

                captureSession.startRunning()

                Task { @MainActor in
                    if delay > 0 {
                        try await Task.sleep(for: .seconds(delay))
                    }

                    let settings = AVCapturePhotoSettings()
                    if photoOutput.supportedFlashModes.contains(flash.avFlashMode) {
                        settings.flashMode = flash.avFlashMode
                    }

                    let delegate = PhotoCaptureDelegate(
                        format: format,
                        quality: quality,
                        completion: { [weak self] result in
                            Task { @MainActor in
                                timeoutTask.cancel()
                                captureSession.stopRunning()
                                self?.currentPhotoDelegate = nil
                                resumeOnce(result)
                            }
                        }
                    )

                    self.currentPhotoDelegate = delegate
                    photoOutput.capturePhoto(with: settings, delegate: delegate)
                }
            }
        }

        Tool(
            name: "capture_record_audio",
            description: "Record audio with the device microphone",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        default: .string(AudioFormat.default.rawValue),
                        enum: AudioFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "duration": .number(
                        description: "Maximum recording duration in seconds",
                        default: 10,
                        minimum: 1,
                        maximum: 300
                    ),
                    "quality": .string(
                        description: "Audio quality",
                        default: "medium",
                        enum: ["low", "medium", "high"]
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Record Audio",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                // Try to request permission if not authorized
                try await self.requestPermission(for: .audio)
            }

            let format =
                AudioFormat(
                    rawValue: arguments["format"]?.stringValue ?? AudioFormat.default.rawValue)
                ?? .mp4
            let duration = arguments["duration"]?.doubleValue ?? 10.0
            let quality = arguments["quality"]?.stringValue ?? "medium"

            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(format.fileExtension)

            let settings: [String: Any] = {
                switch quality {
                case "low":
                    return [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 22050,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,
                    ]
                case "high":
                    return [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ]
                default:  // medium
                    return [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                    ]
                }
            }()

            let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder.record(forDuration: duration)

            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    try await Task.sleep(for: .seconds(duration + 0.5))
                    recorder.stop()

                    do {
                        let audioData = try Data(contentsOf: tempURL)
                        try FileManager.default.removeItem(at: tempURL)
                        let audioValue = Value.data(mimeType: format.mimeType, audioData)
                        continuation.resume(returning: audioValue)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        Tool(
            name: "capture_take_screenshot",
            description: "Take a screenshot of the screen, window, or application",
            inputSchema: .object(
                properties: [
                    "contentType": .string(
                        description: "Type of content to capture",
                        default: .string(ScreenCaptureContentType.default.rawValue),
                        enum: ScreenCaptureContentType.allCases.map { .string($0.rawValue) }
                    ),
                    "format": .string(
                        default: .string(ScreenshotFormat.default.rawValue),
                        enum: ScreenshotFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "quality": .string(
                        description: "Screenshot quality and resolution",
                        default: .string(ScreenCaptureQuality.default.rawValue),
                        enum: ScreenCaptureQuality.allCases.map { .string($0.rawValue) }
                    ),
                    "displayId": .number(
                        description: "Display ID for display capture (optional)",
                        minimum: 0
                    ),
                    "windowId": .number(
                        description: "Window ID for window capture (optional)",
                        minimum: 0
                    ),
                    "bundleId": .string(
                        description: "Bundle ID for application capture (optional)"
                    ),
                    "includesCursor": .boolean(
                        description: "Include cursor in screenshot",
                        default: true
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Take Screenshot",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            if !CGPreflightScreenCaptureAccess() {
                // Try to request permission if not authorized
                try await self.requestScreenRecordingPermission()
            }

            let contentType =
                ScreenCaptureContentType(
                    rawValue: arguments["contentType"]?.stringValue
                        ?? ScreenCaptureContentType.default.rawValue
                ) ?? .display
            let format =
                ScreenshotFormat(
                    rawValue: arguments["format"]?.stringValue ?? ScreenshotFormat.default.rawValue
                ) ?? .png
            let quality =
                ScreenCaptureQuality(
                    rawValue: arguments["quality"]?.stringValue
                        ?? ScreenCaptureQuality.default.rawValue
                ) ?? .medium
            let includesCursor = arguments["includesCursor"]?.boolValue ?? true

            let displayId = arguments["displayId"]?.intValue.map { CGDirectDisplayID($0) }
            let windowId = arguments["windowId"]?.intValue.map { CGWindowID($0) }
            let bundleId = arguments["bundleId"]?.stringValue

            // Get available content
            let availableContent = try await SCShareableContent.getAvailableContent()

            // Create content filter based on content type
            let contentFilter: SCContentFilter
            switch contentType {
            case .display:
                let display: SCDisplay
                if let displayId = displayId {
                    guard
                        let selectedDisplay = availableContent.displays.first(where: {
                            $0.displayID == displayId
                        })
                    else {
                        throw NSError(
                            domain: "CaptureServiceError",
                            code: 20,
                            userInfo: [NSLocalizedDescriptionKey: "Display not found"]
                        )
                    }
                    display = selectedDisplay
                } else {
                    guard let mainDisplay = availableContent.displays.first else {
                        throw NSError(
                            domain: "CaptureServiceError",
                            code: 21,
                            userInfo: [NSLocalizedDescriptionKey: "No displays available"]
                        )
                    }
                    display = mainDisplay
                }
                contentFilter = SCContentFilter(display: display, excludingWindows: [])

            case .window:
                guard let windowId = windowId else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 22,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Window ID required for window capture"
                        ]
                    )
                }
                guard
                    let window = availableContent.windows.first(where: { $0.windowID == windowId })
                else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 23,
                        userInfo: [NSLocalizedDescriptionKey: "Window not found"]
                    )
                }
                contentFilter = SCContentFilter(desktopIndependentWindow: window)

            case .application:
                guard let bundleId = bundleId else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 24,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Bundle ID required for application capture"
                        ]
                    )
                }
                guard
                    let application = availableContent.applications.first(where: {
                        $0.bundleIdentifier == bundleId
                    })
                else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 25,
                        userInfo: [NSLocalizedDescriptionKey: "Application not found"]
                    )
                }
                let appWindows = availableContent.windows.filter {
                    $0.owningApplication == application
                }
                guard let firstDisplay = availableContent.displays.first else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 26,
                        userInfo: [NSLocalizedDescriptionKey: "No displays available for application capture"]
                    )
                }
                contentFilter = SCContentFilter(
                    display: firstDisplay, including: appWindows)
            }

            // Create stream configuration
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.capturesAudio = false
            streamConfiguration.showsCursor = includesCursor
            streamConfiguration.scalesToFit = true
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA

            // Apply quality settings based on the display
            if let display = availableContent.displays.first {
                let scaledWidth = Int(CGFloat(display.width) * quality.scaleFactor)
                let scaledHeight = Int(CGFloat(display.height) * quality.scaleFactor)
                streamConfiguration.width = scaledWidth
                streamConfiguration.height = scaledHeight
            }

            return try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false
                let resumeOnce = { (result: Result<Value, Error>) in
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(with: result)
                }

                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(10))
                    if !hasResumed {
                        resumeOnce(
                            .failure(
                                NSError(
                                    domain: "CaptureServiceError",
                                    code: 26,
                                    userInfo: [
                                        NSLocalizedDescriptionKey: "Screenshot capture timeout"
                                    ]
                                )
                            )
                        )
                    }
                }

                Task {
                    do {
                        // Use SCScreenshotManager for taking screenshots
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: contentFilter,
                            configuration: streamConfiguration
                        )

                        // Convert CGImage to Data
                        let imageData: Data
                        switch format {
                        case .png:
                            guard let pngData = image.pngData() else {
                                throw NSError(
                                    domain: "CaptureServiceError",
                                    code: 28,
                                    userInfo: [
                                        NSLocalizedDescriptionKey: "Failed to create PNG data"
                                    ]
                                )
                            }
                            imageData = pngData
                        case .jpeg:
                            guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
                                throw NSError(
                                    domain: "CaptureServiceError",
                                    code: 29,
                                    userInfo: [
                                        NSLocalizedDescriptionKey: "Failed to create JPEG data"
                                    ]
                                )
                            }
                            imageData = jpegData
                        }

                        timeoutTask.cancel()
                        let screenshotValue = Value.data(mimeType: format.mimeType, imageData)
                        resumeOnce(.success(screenshotValue))
                    } catch {
                        timeoutTask.cancel()
                        resumeOnce(.failure(error))
                    }
                }
            }
        }

    }
}

// MARK: - Photo Capture Delegate

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let format: ImageFormat
    private let quality: Double
    private let completion: (Result<Value, Swift.Error>) -> Void
    private var hasCompleted = false

    init(
        format: ImageFormat,
        quality: Double,
        completion: @escaping (Result<Value, Swift.Error>) -> Void
    ) {
        self.format = format
        self.quality = quality
        self.completion = completion
        super.init()
    }

    private func complete(with result: Result<Value, Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(result)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            complete(with: .failure(error))
            return
        }

        guard let imageData = photo.fileDataRepresentation() else {
            complete(
                with: .failure(
                    NSError(
                        domain: "CaptureServiceError",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to get image data"]
                    )))
            return
        }

        do {
            let processedData: Data
            let mimeType: String

            if format == .png {
                guard let image = NSImage(data: imageData),
                    let pngData = image.pngData()
                else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to convert to PNG"]
                    )
                }
                processedData = pngData
                mimeType = format.mimeType
            } else {
                guard let image = NSImage(data: imageData),
                    let jpegData = image.jpegData(compressionQuality: quality)
                else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to convert to JPEG"]
                    )
                }
                processedData = jpegData
                mimeType = format.mimeType
            }

            let imageValue = Value.data(mimeType: mimeType, processedData)
            complete(with: .success(imageValue))
        } catch {
            complete(with: .failure(error))
        }
    }
}
