import AVFoundation
import AppKit
import Foundation
import OSLog
import ObjectiveC
import Ontology
import SwiftUI

private let log = Logger.service("camera")

final class CameraService: NSObject, Service {
    static let shared = CameraService()

    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var authorizationContinuation: CheckedContinuation<Void, Error>?
    private var currentDelegate: PhotoCaptureDelegate?

    override init() {
        super.init()
        log.debug("Initializing camera service")
    }

    deinit {
        log.info("Deinitializing camera service")
        captureSession?.stopRunning()
    }

    var isActivated: Bool {
        get async {
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    func activate() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            log.debug("Camera access already authorized")
            return
        case .denied, .restricted:
            log.error("Camera access denied")
            throw NSError(
                domain: "CameraServiceError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Camera access denied"]
            )
        case .notDetermined:
            log.debug("Requesting camera access")
            return try await withCheckedThrowingContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "CameraServiceError",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Camera access denied"]
                            )
                        )
                    }
                }
            }
        @unknown default:
            log.error("Unknown camera authorization status")
            throw NSError(
                domain: "CameraServiceError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown authorization status"]
            )
        }
    }

    var tools: [Tool] {
        Tool(
            name: "camera_take_picture",
            description: "Take a picture with the device camera",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        default: "jpeg",
                        enum: ["jpeg", "png"],
                    ),
                    "quality": .number(
                        description: "JPEG quality",
                        default: 0.8,
                        minimum: 0.0,
                        maximum: 1.0
                    ),
                    "preset": .string(
                        description: "Camera quality preset",
                        default: "photo",
                        enum: [
                            "photo",
                            "low", "medium", "high",
                            "hd1280x720", "hd1920x1080", "hd4K3840x2160",
                        ]
                    ),
                    "device": .string(
                        description: "Camera device type",
                        default: "built-in",
                        enum: [
                            "built-in",
                            "continuity",
                            "external",
                            "desk-view",
                        ]
                    ),
                    "position": .string(
                        description: "Camera position",
                        default: "unspecified",
                        enum: ["unspecified", "back", "front"]
                    ),
                    "flash": .string(
                        description: "Flash mode",
                        default: "auto",
                        enum: ["auto", "on", "off"]
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
            guard await self.isActivated else {
                log.error("Camera access not authorized")
                throw NSError(
                    domain: "CameraServiceError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Camera access not authorized"]
                )
            }

            let format = arguments["format"]?.stringValue ?? "jpeg"
            let quality = arguments["quality"]?.doubleValue ?? 0.8
            let preset = arguments["preset"]?.stringValue ?? "photo"
            let device = arguments["device"]?.stringValue ?? "built-in"
            let position = arguments["position"]?.stringValue ?? "back"
            let flash = arguments["flash"]?.stringValue ?? "auto"
            let autoExposure = arguments["autoExposure"]?.boolValue ?? true
            let autoFocus = arguments["autoFocus"]?.boolValue ?? true
            let autoWhiteBalance = arguments["autoWhiteBalance"]?.boolValue ?? true
            let delay = arguments["delay"]?.doubleValue ?? 1.0

            // Setup capture session inline
            let captureSession = AVCaptureSession()

            // Set session preset
            switch preset {
            case "photo":
                captureSession.sessionPreset = .photo
            case "high":
                captureSession.sessionPreset = .high
            case "medium":
                captureSession.sessionPreset = .medium
            case "low":
                captureSession.sessionPreset = .low
            case "hd1280x720":
                captureSession.sessionPreset = .hd1280x720
            case "hd1920x1080":
                captureSession.sessionPreset = .hd1920x1080
            case "hd4K3840x2160":
                captureSession.sessionPreset = .hd4K3840x2160
            default:
                captureSession.sessionPreset = .photo
            }

            // Select camera device
            let cameraPosition: AVCaptureDevice.Position? = {
                switch position {
                case "front": return .front
                case "back": return .back
                case "unspecified": return .unspecified
                default: return nil
                }
            }()

            let deviceType: AVCaptureDevice.DeviceType? = {
                switch device {
                case "built-in": return .builtInWideAngleCamera
                case "continuity": return .continuityCamera
                case "desk-view": return .deskViewCamera
                case "external": return .external
                default: return nil
                }
            }()

            let videoDevice: AVCaptureDevice? = {
                // Use default for video unless we have valid device type and position
                guard let deviceType,
                    let cameraPosition, cameraPosition != .unspecified
                else {
                    return AVCaptureDevice.default(for: .video)
                }

                // Try to get device with specific type and position
                if let device = AVCaptureDevice.default(
                    deviceType, for: .video, position: cameraPosition)
                {
                    return device
                }

                // Fallback to any device with specified position
                return AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: cameraPosition)
            }()

            guard let device = videoDevice else {
                throw NSError(
                    domain: "CameraServiceError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No camera device found for type: \(deviceType.debugDescription), position: \(position.debugDescription)"
                    ]
                )
            }

            // Configure camera device settings
            do {
                try device.lockForConfiguration()

                // Set auto exposure
                if autoExposure && device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }

                // Set auto focus
                if autoFocus && device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }

                // Set auto white balance
                if autoWhiteBalance && device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                    device.whiteBalanceMode = .autoWhiteBalance
                }

                device.unlockForConfiguration()
            } catch {
                log.warning("Failed to configure camera device: \(error.localizedDescription)")
            }

            let videoInput = try AVCaptureDeviceInput(device: device)

            guard captureSession.canAddInput(videoInput) else {
                throw NSError(
                    domain: "CameraServiceError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"]
                )
            }

            captureSession.addInput(videoInput)

            let photoOutput = AVCapturePhotoOutput()

            guard captureSession.canAddOutput(photoOutput) else {
                throw NSError(
                    domain: "CameraServiceError",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add photo output"]
                )
            }

            captureSession.addOutput(photoOutput)

            // Take picture
            return try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false
                let resumeOnce = { (result: Result<Value, Error>) in
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(with: result)
                }

                // Create timeout task
                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(10))
                    if !hasResumed {
                        await MainActor.run {
                            captureSession.stopRunning()
                            self.currentDelegate = nil
                        }
                        resumeOnce(
                            .failure(
                                NSError(
                                    domain: "CameraServiceError",
                                    code: 9,
                                    userInfo: [
                                        NSLocalizedDescriptionKey: "Camera capture timeout"
                                    ]
                                ))
                        )
                    }
                }

                captureSession.startRunning()

                Task { @MainActor in
                    // Apply delay before taking photo
                    if delay > 0 {
                        try await Task.sleep(for: .seconds(delay))
                    }

                    let settings = AVCapturePhotoSettings()

                    // Configure flash
                    if photoOutput.supportedFlashModes.contains(.auto) && flash == "auto" {
                        settings.flashMode = .auto
                    } else if photoOutput.supportedFlashModes.contains(.on) && flash == "on" {
                        settings.flashMode = .on
                    } else if photoOutput.supportedFlashModes.contains(.off) && flash == "off" {
                        settings.flashMode = .off
                    }

                    let delegate = PhotoCaptureDelegate(
                        format: format,
                        quality: quality,
                        completion: { [weak self] result in
                            Task { @MainActor in
                                timeoutTask.cancel()
                                captureSession.stopRunning()
                                self?.currentDelegate = nil
                                log.debug("Camera delegate completed with result")
                                resumeOnce(result)
                            }
                        }
                    )

                    self.currentDelegate = delegate
                    photoOutput.capturePhoto(with: settings, delegate: delegate)
                }
            }
        }
    }
}

// MARK: -

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let format: String
    private let quality: Double
    private let completion: (Result<Value, Swift.Error>) -> Void
    private var hasCompleted = false

    init(
        format: String,
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
        log.debug("photoOutput didFinishProcessingPhoto called")
        if let error = error {
            log.error("Photo capture error: \(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        guard let imageData = photo.fileDataRepresentation() else {
            completion(
                .failure(
                    NSError(
                        domain: "CameraServiceError",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to get image data"]
                    )))
            return
        }

        do {
            let processedData: Data
            let mimeType: String

            if format == "png" {
                guard let image = NSImage(data: imageData),
                    let pngData = image.pngData()
                else {
                    throw NSError(
                        domain: "CameraServiceError",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to convert to PNG"]
                    )
                }
                processedData = pngData
                mimeType = "image/png"
            } else {
                guard let image = NSImage(data: imageData),
                    let jpegData = image.jpegData(compressionQuality: quality)
                else {
                    throw NSError(
                        domain: "CameraServiceError",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to convert to JPEG"]
                    )
                }
                processedData = jpegData
                mimeType = "image/jpeg"
            }

            let imageValue = Value.data(mimeType: mimeType, processedData)
            log.debug("Camera captured image: \(mimeType), size: \(processedData.count) bytes")
            complete(with: .success(imageValue))
        } catch {
            complete(with: .failure(error))
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
    ) {
        if let error = error {
            complete(with: .failure(error))
        }
    }
}
