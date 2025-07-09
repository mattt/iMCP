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
    private var movieFileOutput: AVCaptureMovieFileOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var currentPhotoDelegate: PhotoCaptureDelegate?
    private var currentMovieDelegate: MovieCaptureDelegate?
    private var currentAudioDelegate: AudioCaptureDelegate?

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
            return cameraAuthorized || microphoneAuthorized
        }
    }

    func activate() async throws {
        try await requestPermission(for: .video)
        try await requestPermission(for: .audio)
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
            return try await withCheckedThrowingContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    if granted {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "CaptureServiceError",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "\(mediaName) access denied"]
                            )
                        )
                    }
                }
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
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.takePicture(arguments: arguments)
        }

        Tool(
            name: "capture_record_video",
            description: "Record a video with the device camera and microphone",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        default: .string(VideoFormat.default.rawValue),
                        enum: VideoFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "duration": .number(
                        description: "Maximum recording duration in seconds",
                        default: 10,
                        minimum: 1,
                        maximum: 300
                    ),
                    "preset": .string(
                        description: "Video quality preset",
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
                    "includeAudio": .boolean(
                        description: "Include audio in video recording",
                        default: true
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
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Record Video",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.recordVideo(arguments: arguments)
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
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.recordAudio(arguments: arguments)
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
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.takeScreenshot(arguments: arguments)
        }

        Tool(
            name: "capture_record_screen",
            description: "Record screen, window, or application video",
            inputSchema: .object(
                properties: [
                    "contentType": .string(
                        description: "Type of content to record",
                        default: .string(ScreenCaptureContentType.default.rawValue),
                        enum: ScreenCaptureContentType.allCases.map { .string($0.rawValue) }
                    ),
                    "format": .string(
                        default: .string(ScreenRecordingFormat.default.rawValue),
                        enum: ScreenRecordingFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "duration": .number(
                        description: "Maximum recording duration in seconds",
                        default: 10,
                        minimum: 1,
                        maximum: 300
                    ),
                    "quality": .string(
                        description: "Recording quality and resolution",
                        default: .string(ScreenCaptureQuality.default.rawValue),
                        enum: ScreenCaptureQuality.allCases.map { .string($0.rawValue) }
                    ),
                    "frameRate": .string(
                        description: "Recording frame rate",
                        default: .string(ScreenCaptureFrameRate.default.rawValue),
                        enum: ScreenCaptureFrameRate.allCases.map { .string($0.rawValue) }
                    ),
                    "displayId": .number(
                        description: "Display ID for display recording (optional)",
                        minimum: 0
                    ),
                    "windowId": .number(
                        description: "Window ID for window recording (optional)",
                        minimum: 0
                    ),
                    "bundleId": .string(
                        description: "Bundle ID for application recording (optional)"
                    ),
                    "includesCursor": .boolean(
                        description: "Include cursor in recording",
                        default: true
                    ),
                    "includesAudio": .boolean(
                        description: "Include system audio in recording",
                        default: false
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Record Screen",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.recordScreen(arguments: arguments)
        }
    }

    // MARK: - Photo Capture

    private func takePicture(arguments: [String: Value]) async throws -> Value {
        guard await isActivated else {
            throw NSError(
                domain: "CaptureServiceError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Camera access not authorized"]
            )
        }

        let format =
            ImageFormat(rawValue: arguments["format"]?.stringValue ?? ImageFormat.default.rawValue)
            ?? .jpeg
        let quality = arguments["quality"]?.doubleValue ?? 0.8
        let preset =
            SessionPreset(
                rawValue: arguments["preset"]?.stringValue ?? SessionPreset.default.rawValue)
            ?? .photo
        let device =
            CaptureDeviceType(
                rawValue: arguments["device"]?.stringValue ?? CaptureDeviceType.default.rawValue)
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
            let videoDevice = AVCaptureDevice.device(
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

        try await configureDevice(
            videoDevice, autoExposure: autoExposure, autoFocus: autoFocus,
            autoWhiteBalance: autoWhiteBalance)

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
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

    // MARK: - Video Recording

    private func recordVideo(arguments: [String: Value]) async throws -> Value {
        guard await isActivated else {
            throw NSError(
                domain: "CaptureServiceError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Camera and microphone access not authorized"]
            )
        }

        let format =
            VideoFormat(rawValue: arguments["format"]?.stringValue ?? VideoFormat.default.rawValue)
            ?? .mp4
        let duration = arguments["duration"]?.doubleValue ?? 10.0
        let preset =
            SessionPreset(
                rawValue: arguments["preset"]?.stringValue ?? SessionPreset.default.rawValue)
            ?? .high
        let device =
            CaptureDeviceType(
                rawValue: arguments["device"]?.stringValue ?? CaptureDeviceType.default.rawValue)
            ?? .builtInWideAngle
        let position =
            CaptureDevicePosition(
                rawValue: arguments["position"]?.stringValue
                    ?? CaptureDevicePosition.default.rawValue
            ) ?? .unspecified
        let includeAudio = arguments["includeAudio"]?.boolValue ?? true
        let autoExposure = arguments["autoExposure"]?.boolValue ?? true
        let autoFocus = arguments["autoFocus"]?.boolValue ?? true
        let autoWhiteBalance = arguments["autoWhiteBalance"]?.boolValue ?? true

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = preset.avPreset

        // Add video input
        guard
            let videoDevice = AVCaptureDevice.device(
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

        try await configureDevice(
            videoDevice, autoExposure: autoExposure, autoFocus: autoFocus,
            autoWhiteBalance: autoWhiteBalance)

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard captureSession.canAddInput(videoInput) else {
            throw NSError(
                domain: "CaptureServiceError",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"]
            )
        }
        captureSession.addInput(videoInput)

        // Add audio input if requested
        if includeAudio {
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "No audio device found"]
                )
            }

            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            guard captureSession.canAddInput(audioInput) else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input"]
                )
            }
            captureSession.addInput(audioInput)
        }

        let movieOutput = AVCaptureMovieFileOutput()
        guard captureSession.canAddOutput(movieOutput) else {
            throw NSError(
                domain: "CaptureServiceError",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add movie output"]
            )
        }
        captureSession.addOutput(movieOutput)

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resumeOnce = { (result: Result<Value, Error>) in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(duration + 5))
                if !hasResumed {
                    await MainActor.run {
                        movieOutput.stopRecording()
                        captureSession.stopRunning()
                        self.currentMovieDelegate = nil
                    }
                    resumeOnce(
                        .failure(
                            NSError(
                                domain: "CaptureServiceError",
                                code: 13,
                                userInfo: [NSLocalizedDescriptionKey: "Video recording timeout"]
                            )))
                }
            }

            Task { @MainActor in
                let delegate = MovieCaptureDelegate(
                    format: format,
                    completion: { [weak self] result in
                        Task { @MainActor in
                            timeoutTask.cancel()
                            captureSession.stopRunning()
                            self?.currentMovieDelegate = nil
                            resumeOnce(result)
                        }
                    }
                )

                self.currentMovieDelegate = delegate
                captureSession.startRunning()

                // Stop recording after specified duration
                Task {
                    try await Task.sleep(for: .seconds(duration))
                    if !hasResumed {
                        await MainActor.run {
                            movieOutput.stopRecording()
                        }
                    }
                }

                movieOutput.startRecording(to: tempURL, recordingDelegate: delegate)
            }
        }
    }

    // MARK: - Screenshot Capture

    private func takeScreenshot(arguments: [String: Value]) async throws -> Value {
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
                rawValue: arguments["quality"]?.stringValue ?? ScreenCaptureQuality.default.rawValue
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
                    userInfo: [NSLocalizedDescriptionKey: "Window ID required for window capture"]
                )
            }
            guard let window = availableContent.windows.first(where: { $0.windowID == windowId })
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
            let appWindows = availableContent.windows.filter { $0.owningApplication == application }
            contentFilter = SCContentFilter(
                display: availableContent.displays.first!, including: appWindows)
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
                                userInfo: [NSLocalizedDescriptionKey: "Screenshot capture timeout"]
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
                                userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"]
                            )
                        }
                        imageData = pngData
                    case .jpeg:
                        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
                            throw NSError(
                                domain: "CaptureServiceError",
                                code: 29,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to create JPEG data"]
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

    // MARK: - Screen Recording

    private func recordScreen(arguments: [String: Value]) async throws -> Value {
        let contentType =
            ScreenCaptureContentType(
                rawValue: arguments["contentType"]?.stringValue
                    ?? ScreenCaptureContentType.default.rawValue
            ) ?? .display
        let format =
            ScreenRecordingFormat(
                rawValue: arguments["format"]?.stringValue ?? ScreenRecordingFormat.default.rawValue
            ) ?? .mp4
        let duration = arguments["duration"]?.doubleValue ?? 10.0
        let quality =
            ScreenCaptureQuality(
                rawValue: arguments["quality"]?.stringValue ?? ScreenCaptureQuality.default.rawValue
            ) ?? .medium
        let frameRate =
            ScreenCaptureFrameRate(
                rawValue: arguments["frameRate"]?.stringValue
                    ?? ScreenCaptureFrameRate.default.rawValue
            ) ?? .fps30
        let includesCursor = arguments["includesCursor"]?.boolValue ?? true
        let includesAudio = arguments["includesAudio"]?.boolValue ?? false

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
                        code: 30,
                        userInfo: [NSLocalizedDescriptionKey: "Display not found"]
                    )
                }
                display = selectedDisplay
            } else {
                guard let mainDisplay = availableContent.displays.first else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 31,
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
                    code: 32,
                    userInfo: [NSLocalizedDescriptionKey: "Window ID required for window capture"]
                )
            }
            guard let window = availableContent.windows.first(where: { $0.windowID == windowId })
            else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 33,
                    userInfo: [NSLocalizedDescriptionKey: "Window not found"]
                )
            }
            contentFilter = SCContentFilter(desktopIndependentWindow: window)

        case .application:
            guard let bundleId = bundleId else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 34,
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
                    code: 35,
                    userInfo: [NSLocalizedDescriptionKey: "Application not found"]
                )
            }
            let appWindows = availableContent.windows.filter { $0.owningApplication == application }
            contentFilter = SCContentFilter(
                display: availableContent.displays.first!, including: appWindows)
        }

        // Create stream configuration
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.capturesAudio = includesAudio
        streamConfiguration.showsCursor = includesCursor
        streamConfiguration.scalesToFit = true
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(frameRate.value))

        // Apply quality settings based on the display
        if let display = availableContent.displays.first {
            let scaledWidth = Int(CGFloat(display.width) * quality.scaleFactor)
            let scaledHeight = Int(CGFloat(display.height) * quality.scaleFactor)
            streamConfiguration.width = scaledWidth
            streamConfiguration.height = scaledHeight
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resumeOnce = { (result: Result<Value, Error>) in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(duration + 5))
                if !hasResumed {
                    resumeOnce(
                        .failure(
                            NSError(
                                domain: "CaptureServiceError",
                                code: 36,
                                userInfo: [NSLocalizedDescriptionKey: "Screen recording timeout"]
                            )
                        )
                    )
                }
            }

            Task {
                do {
                    // Create video writer
                    let videoWriter = try AVAssetWriter(
                        outputURL: tempURL, fileType: format == .mp4 ? .mp4 : .mov)

                    let videoSettings: [String: Any] = [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: streamConfiguration.width,
                        AVVideoHeightKey: streamConfiguration.height,
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: quality == .high
                                ? 5_000_000 : (quality == .medium ? 2_500_000 : 1_000_000),
                            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                        ],
                    ]

                    let videoWriterInput = AVAssetWriterInput(
                        mediaType: .video, outputSettings: videoSettings)
                    videoWriterInput.expectsMediaDataInRealTime = true

                    let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                        assetWriterInput: videoWriterInput,
                        sourcePixelBufferAttributes: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                        ]
                    )

                    guard videoWriter.canAdd(videoWriterInput) else {
                        throw NSError(
                            domain: "CaptureServiceError",
                            code: 37,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Cannot add video input to writer"
                            ]
                        )
                    }
                    videoWriter.add(videoWriterInput)

                    // Start writing
                    guard videoWriter.startWriting() else {
                        throw NSError(
                            domain: "CaptureServiceError",
                            code: 38,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to start video writing"]
                        )
                    }
                    videoWriter.startSession(atSourceTime: .zero)

                    // Create delegate for handling stream output
                    let delegate = ScreenRecordingDelegate(
                        pixelBufferAdaptor: pixelBufferAdaptor,
                        videoWriterInput: videoWriterInput,
                        completion: { result in
                            Task {
                                timeoutTask.cancel()

                                videoWriter.finishWriting {
                                    do {
                                        if videoWriter.status == .completed {
                                            let videoData = try Data(contentsOf: tempURL)
                                            try FileManager.default.removeItem(at: tempURL)
                                            let videoValue = Value.data(
                                                mimeType: format.mimeType, videoData)
                                            resumeOnce(.success(videoValue))
                                        } else {
                                            throw NSError(
                                                domain: "CaptureServiceError",
                                                code: 39,
                                                userInfo: [
                                                    NSLocalizedDescriptionKey:
                                                        "Video writing failed"
                                                ]
                                            )
                                        }
                                    } catch {
                                        resumeOnce(.failure(error))
                                    }
                                }
                            }
                        }
                    )

                    // Create the stream with delegate
                    let stream = SCStream(
                        filter: contentFilter, configuration: streamConfiguration,
                        delegate: delegate)

                    // Start the stream
                    try await stream.startCapture()

                    // Stop recording after specified duration
                    Task {
                        try await Task.sleep(for: .seconds(duration))
                        try await stream.stopCapture()
                        delegate.complete(with: .success(Value.null))
                    }

                } catch {
                    timeoutTask.cancel()
                    resumeOnce(.failure(error))
                }
            }
        }
    }

    // MARK: - Audio Recording

    private func recordAudio(arguments: [String: Value]) async throws -> Value {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(
                domain: "CaptureServiceError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access not authorized"]
            )
        }

        let format =
            AudioFormat(rawValue: arguments["format"]?.stringValue ?? AudioFormat.default.rawValue)
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

    // MARK: - Helper Methods

    private func configureDevice(
        _ device: AVCaptureDevice,
        autoExposure: Bool,
        autoFocus: Bool,
        autoWhiteBalance: Bool
    ) async throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if autoExposure && device.isExposureModeSupported(.autoExpose) {
            device.exposureMode = .autoExpose
        }

        if autoFocus && device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }

        if autoWhiteBalance && device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
            device.whiteBalanceMode = .autoWhiteBalance
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

// MARK: - Movie Capture Delegate

private class MovieCaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let format: VideoFormat
    private let completion: (Result<Value, Swift.Error>) -> Void
    private var hasCompleted = false

    init(
        format: VideoFormat,
        completion: @escaping (Result<Value, Swift.Error>) -> Void
    ) {
        self.format = format
        self.completion = completion
        super.init()
    }

    private func complete(with result: Result<Value, Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(result)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error = error {
            complete(with: .failure(error))
            return
        }

        do {
            let videoData = try Data(contentsOf: outputFileURL)
            try FileManager.default.removeItem(at: outputFileURL)
            let videoValue = Value.data(mimeType: format.mimeType, videoData)
            complete(with: .success(videoValue))
        } catch {
            complete(with: .failure(error))
        }
    }
}

// MARK: - Audio Capture Delegate

private class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let format: AudioFormat
    private let completion: (Result<Value, Swift.Error>) -> Void
    private var hasCompleted = false

    init(
        format: AudioFormat,
        completion: @escaping (Result<Value, Swift.Error>) -> Void
    ) {
        self.format = format
        self.completion = completion
        super.init()
    }

    private func complete(with result: Result<Value, Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(result)
    }
}

// MARK: - Screen Recording Delegate

private class ScreenRecordingDelegate: NSObject, SCStreamDelegate {
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let videoWriterInput: AVAssetWriterInput
    private let completion: (Result<Value, Swift.Error>) -> Void
    private var hasCompleted = false
    private var startTime: CMTime?

    init(
        pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor,
        videoWriterInput: AVAssetWriterInput,
        completion: @escaping (Result<Value, Swift.Error>) -> Void
    ) {
        self.pixelBufferAdaptor = pixelBufferAdaptor
        self.videoWriterInput = videoWriterInput
        self.completion = completion
        super.init()
    }

    func complete(with result: Result<Value, Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(result)
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if startTime == nil {
            startTime = timestamp
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if videoWriterInput.isReadyForMoreMediaData {
            let relativeTime = CMTimeSubtract(timestamp, startTime ?? .zero)
            pixelBufferAdaptor.append(imageBuffer, withPresentationTime: relativeTime)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        complete(with: .failure(error))
    }
}
