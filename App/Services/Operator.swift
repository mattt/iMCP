import ApplicationServices
import Foundation
import Cocoa
import CoreServices
import OSLog
import AVFoundation
import Ontology

private let log = Logger.service("operator")

final class OperatorService: Service {
    static let shared = OperatorService()
    
    var isActivated: Bool {
        get async {
            return AXIsProcessTrusted()
        }
    }
    
    func activate() async throws {

        log.debug("Activating operator service")
        
        // Check if already trusted first
        if AXIsProcessTrusted() {
            log.debug("Accessibility access already granted")
        }
        
        log.debug("Accessibility access not granted, requesting permission")
        // Request accessibility access with prompt
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]

        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        log.debug("Accessibility access enabled after prompt: \(accessEnabled)")
        
        if !accessEnabled {
            throw NSError(
                domain: "OperatorError", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Accessibility access required. Please grant access in System Preferences > Security & Privacy > Privacy > Accessibility and restart the application."]
            )
        }
        
        // Request screen recording access
        if !CGRequestScreenCaptureAccess() {
            throw NSError(
                domain: "OperatorError", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Screen recording access required. Please grant access in System Preferences > Security & Privacy > Privacy > Screen Recording"]
            )
        }
        
    }
    
    var tools: [Tool] {
        Tool(
            name: "operator_list_apps",
            description: "List all running applications",
            inputSchema: .object(
                properties: [
                    "filter": .string(description: "Optional filter string to search app names")
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Apps",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let filter = arguments["filter"]?.stringValue
            return Value.string(listApps(filter: filter))
        }
        
        Tool(
            name: "operator_list_windows",
            description: "List all windows for a specific application",
            inputSchema: .object(
                properties: [
                    "app": .string(description: "Application name or bundle ID")
                ],
                required: ["app"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Windows",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let app = arguments["app"]?.stringValue else {
                throw NSError(domain: "OperatorError", code: 2, 
                            userInfo: [NSLocalizedDescriptionKey: "Missing app parameter"])
            }
            return Value.string(getAppWindows(app: app))
        }
        
        Tool(
            name: "operator_screenshot_window",
            description: "Take a screenshot of a specific window",
            inputSchema: .object(
                properties: [
                    "app": .string(description: "Application name or bundle ID"),
                    "window": .string(description: "Window title")
                ],
                required: ["app", "window"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Screenshot Window",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let app = arguments["app"]?.stringValue,
                  let window = arguments["window"]?.stringValue else {
                throw NSError(domain: "OperatorError", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Missing app or window parameter"])
            }
            return Value.string(try getWindowScreenshotBase64(app: app, window: window))
        }
        
        Tool(
            name: "operator_list_elements",
            description: "List all UI elements in a window",
            inputSchema: .object(
                properties: [
                    "app": .string(description: "Application name or bundle ID"),
                    "window": .string(description: "Window title")
                ],
                required: ["app", "window"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Elements",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let app = arguments["app"]?.stringValue,
                  let window = arguments["window"]?.stringValue else {
                throw NSError(domain: "OperatorError", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Missing app or window parameter"])
            }
            return Value.string(listWindowElements(app: app, window: window))
        }
        
        Tool(
            name: "operator_press_element",
            description: "Press/click a UI element",
            inputSchema: .object(
                properties: [
                    "app": .string(description: "Application name or bundle ID"),
                    "window": .string(description: "Window title"),
                    "element": .string(description: "Element identifier (role, title, or description)")
                ],
                required: ["app", "window", "element"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Press Element",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let app = arguments["app"]?.stringValue,
                  let window = arguments["window"]?.stringValue,
                  let element = arguments["element"]?.stringValue else {
                throw NSError(domain: "OperatorError", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Missing required parameters"])
            }
            return Value.string(pressElementResult(app: app, window: window, element: element))
        }
        
        Tool(
            name: "operator_input_text",
            description: "Input text into a UI element",
            inputSchema: .object(
                properties: [
                    "app": .string(description: "Application name or bundle ID"),
                    "window": .string(description: "Window title"),
                    "element": .string(description: "Element identifier (role, title, or description)"),
                    "text": .string(description: "Text to input")
                ],
                required: ["app", "window", "element", "text"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Input Text",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let app = arguments["app"]?.stringValue,
                  let window = arguments["window"]?.stringValue,
                  let element = arguments["element"]?.stringValue,
                  let text = arguments["text"]?.stringValue else {
                throw NSError(domain: "OperatorError", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Missing required parameters"])
            }
            return Value.string(setFieldTextResult(app: app, window: window, element: element, text: text))
        }
    }
}



// Helper function to find app by bundle ID or name
private func findApp(_ identifier: String) -> NSRunningApplication? {
    let runningApps = NSWorkspace.shared.runningApplications
    
    // Try exact match first
    if let exactMatch = runningApps.first(where: { app in
        app.bundleIdentifier == identifier || app.localizedName == identifier
    }) {
        return exactMatch
    }
    
    // Try case-insensitive match
    if let caseInsensitiveMatch = runningApps.first(where: { app in
        app.bundleIdentifier?.lowercased() == identifier.lowercased() || 
        app.localizedName?.lowercased() == identifier.lowercased()
    }) {
        return caseInsensitiveMatch
    }
    
    // Try partial match (contains)
    return runningApps.first { app in
        app.bundleIdentifier?.lowercased().contains(identifier.lowercased()) == true ||
        app.localizedName?.lowercased().contains(identifier.lowercased()) == true
    }
}

// Helper function to find window by title
private func findWindow(in app: NSRunningApplication, title: String) -> AXUIElement? {
    let pid = app.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)
    
    var windows: CFArray?
    let result = AXUIElementCopyAttributeValues(appElement, kAXWindowsAttribute as CFString, 0, 100, &windows)
    
    guard result == .success, let windowArray = windows as? [AXUIElement] else {
        return nil
    }
    
    var allWindows: [(AXUIElement, String)] = []
    for window in windowArray {
        var windowTitle: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitle)
        if let winTitle = windowTitle as? String {
            allWindows.append((window, winTitle))
        }
    }
    
    // Try exact match first
    if let exactMatch = allWindows.first(where: { $0.1 == title }) {
        return exactMatch.0
    }
    
    // Try case-insensitive match
    if let caseInsensitiveMatch = allWindows.first(where: { $0.1.lowercased() == title.lowercased() }) {
        return caseInsensitiveMatch.0
    }
    
    // Try partial match (contains)
    if let partialMatch = allWindows.first(where: { $0.1.lowercased().contains(title.lowercased()) }) {
        return partialMatch.0
    }
    
    return nil
}

// Helper function to find element by role and title/description
private func findElement(in window: AXUIElement, identifier: String) -> AXUIElement? {
    var elementsToProcess: [AXUIElement] = [window]
    
    while !elementsToProcess.isEmpty {
        let element = elementsToProcess.removeFirst()
        
        var role: CFTypeRef?
        var title: CFTypeRef?
        var description: CFTypeRef?
        
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
        
        let roleStr = role as? String ?? ""
        let titleStr = title as? String ?? ""
        let descStr = description as? String ?? ""
        
        // Match by role, title, or description
        if roleStr.contains(identifier) || titleStr.contains(identifier) || descStr.contains(identifier) {
            return element
        }
        
        // Get children
        var children: CFArray?
        let result = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 1000, &children)
        if result == .success, let childArray = children as? [AXUIElement] {
            elementsToProcess.append(contentsOf: childArray)
        }
    }
    return nil
}

// List all apps running with their names and bundleIds
func listApps(filter: String?) -> String {
    let runningApps = NSWorkspace.shared.runningApplications
    var result: [String] = []
    
    for app in runningApps {
        guard let bundleId = app.bundleIdentifier,
              let appName = app.localizedName else { continue }
        
        let appInfo = "\(appName) (\(bundleId))"
        
        if let filter = filter {
            if appName.lowercased().contains(filter.lowercased()) || 
               bundleId.lowercased().contains(filter.lowercased()) {
                result.append(appInfo)
            }
        } else {
            result.append(appInfo)
        }
    }
    
    return result.joined(separator: "\n")
}

// List all windows of an app
func getAppWindows(app: String) -> String {
    guard let targetApp = findApp(app) else {
        return "App not found: \(app)"
    }
    
    let pid = targetApp.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)
    
    var windows: CFArray?
    let result = AXUIElementCopyAttributeValues(appElement, kAXWindowsAttribute as CFString, 0, 100, &windows)
    
    guard result == .success, let windowArray = windows as? [AXUIElement] else {
        log.error("Failed to get windows for \(app): AXError \(result.rawValue)")
        return "Could not get windows for \(app): AXError \(result.rawValue)"
    }
    
    var windowTitles: [String] = []
    for window in windowArray {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        let windowTitle = title as? String ?? "(Untitled)"
        windowTitles.append(windowTitle)
    }
    
    return windowTitles.joined(separator: "\n")
}

// Get a screenshot of a window and return as base64
private func getWindowScreenshotBase64(app: String, window: String) throws -> String {
    guard let targetApp = findApp(app),
          let targetWindow = findWindow(in: targetApp, title: window) else {
        throw NSError(domain: "OperatorError", code: 3,
                     userInfo: [NSLocalizedDescriptionKey: "App or window not found"])
    }
    
    var bounds: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(targetWindow, "AXFrame" as CFString, &bounds)
    
    guard result == .success,
          let frameValue = bounds,
          CFGetTypeID(frameValue) == AXValueGetTypeID() else {
        throw NSError(domain: "OperatorError", code: 4,
                     userInfo: [NSLocalizedDescriptionKey: "Could not get window bounds"])
    }
    
    var rect = CGRect.zero
    let success = AXValueGetValue(frameValue as! AXValue, .cgRect, &rect)
    guard success else {
        throw NSError(domain: "OperatorError", code: 5,
                     userInfo: [NSLocalizedDescriptionKey: "Could not extract window bounds"])
    }
    
    // Create temporary file for screenshot
    let tempDir = FileManager.default.temporaryDirectory
    let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".png")
    
    // Use screencapture command line tool with region coordinates
    let x = Int(rect.origin.x)
    let y = Int(rect.origin.y)
    let width = Int(rect.size.width)
    let height = Int(rect.size.height)
    
    let process = Process()
    process.launchPath = "/usr/sbin/screencapture"
    process.arguments = ["-R", "\(x),\(y),\(width),\(height)", tempFile.path]
    
    do {
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "OperatorError", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Screenshot failed - screen recording permission required"])
        }
        
        // Read the image file and convert to base64
        let imageData = try Data(contentsOf: tempFile)
        let base64String = imageData.base64EncodedString()
        
        // Clean up temporary file
        try? FileManager.default.removeItem(at: tempFile)
        
        return base64String
    } catch {
        // Clean up temporary file on error
        try? FileManager.default.removeItem(at: tempFile)
        throw error
    }
}

// Legacy function for compatibility
func getWindowScreenshot(app: String, window: String) -> String {
    do {
        let base64 = try getWindowScreenshotBase64(app: app, window: window)
        return "Screenshot captured as base64: \(base64.prefix(50))..."
    } catch {
        return "Screenshot failed: \(error.localizedDescription)"
    }
}

// List all elements in a window recursively
func listWindowElements(app: String, window: String) -> String {
    guard let targetApp = findApp(app),
          let targetWindow = findWindow(in: targetApp, title: window) else {
        return "<error>App or window not found</error>"
    }
    
    func buildElementXML(_ element: AXUIElement, depth: Int = 0) -> String {
        let indent = String(repeating: "  ", count: depth)
        
        var role: CFTypeRef?
        var title: CFTypeRef?
        var description: CFTypeRef?
        var value: CFTypeRef?
        
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        
        let roleStr = role as? String ?? "Unknown"
        let titleStr = title as? String
        let descStr = description as? String
        let valueStr = value as? String
        
        var xml = "\(indent)<element role=\"\(roleStr)\""
        if let titleStr = titleStr, !titleStr.isEmpty {
            xml += " title=\"\(titleStr.replacingOccurrences(of: "\"", with: "&quot;"))\""
        }
        if let descStr = descStr, !descStr.isEmpty {
            xml += " description=\"\(descStr.replacingOccurrences(of: "\"", with: "&quot;"))\""
        }
        if let valueStr = valueStr, !valueStr.isEmpty {
            xml += " value=\"\(valueStr.replacingOccurrences(of: "\"", with: "&quot;"))\""
        }
        
        var children: CFArray?
        let result = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 1000, &children)
        
        if result == .success, let childArray = children as? [AXUIElement], !childArray.isEmpty {
            xml += ">\n"
            for child in childArray {
                xml += buildElementXML(child, depth: depth + 1)
            }
            xml += "\(indent)</element>\n"
        } else {
            xml += "/>\n"
        }
        
        return xml
    }
    
    return "<window>\n\(buildElementXML(targetWindow, depth: 1))</window>"
}

// Finds the element and then press it - returns success/failure string
private func pressElementResult(app: String, window: String, element: String) -> String {
    guard let targetApp = findApp(app),
          let targetWindow = findWindow(in: targetApp, title: window),
          let targetElement = findElement(in: targetWindow, identifier: element) else {
        return "failure"
    }
    
    let result = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
    return result == .success ? "success" : "failure"
}

// Legacy function for compatibility
func pressElement(app: String, window: String, element: String) {
    let result = pressElementResult(app: app, window: window, element: element)
    print(result == "success" ? "Element pressed successfully" : "Press failed")
}

// Set text in field - returns success/failure string
private func setFieldTextResult(app: String, window: String, element: String, text: String) -> String {
    guard let targetApp = findApp(app),
          let targetWindow = findWindow(in: targetApp, title: window),
          let targetElement = findElement(in: targetWindow, identifier: element) else {
        return "failure"
    }
    
    let result = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, text as CFString)
    return result == .success ? "success" : "failure"
}

// Legacy function for compatibility
func setFieldText(app: String, window: String, element: String, text: String) {
    let result = setFieldTextResult(app: app, window: window, element: element, text: text)
    print(result == "success" ? "Text set successfully" : "Set text failed")
}