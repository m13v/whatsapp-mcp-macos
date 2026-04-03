import MCP
import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import MacosUseSDK

// MARK: - Helper Functions

func serializeToJsonString<T: Encodable>(_ value: T) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        let jsonData = try encoder.encode(value)
        return String(data: jsonData, encoding: .utf8)
    } catch {
        fputs("error: serializeToJsonString: \(error)\n", stderr)
        return nil
    }
}

func getRequiredString(from args: [String: Value]?, key: String) throws -> String {
    guard let val = args?[key]?.stringValue else {
        throw MCPError.invalidParams("Missing or invalid required string argument: '\(key)'")
    }
    return val
}

func getOptionalString(from args: [String: Value]?, key: String) -> String? {
    guard let value = args?[key] else { return nil }
    if value.isNull { return nil }
    return value.stringValue
}

func getOptionalInt(from args: [String: Value]?, key: String) throws -> Int? {
    guard let value = args?[key] else { return nil }
    if value.isNull { return nil }
    if let doubleValue = value.doubleValue {
        if let intValue = Int(exactly: doubleValue) { return intValue }
        throw MCPError.invalidParams("Invalid type for optional integer argument: '\(key)', received non-exact Double \(doubleValue)")
    }
    if let stringValue = value.stringValue, let intValue = Int(stringValue) { return intValue }
    guard let intValue = value.intValue else {
        throw MCPError.invalidParams("Invalid type for optional integer argument: '\(key)', expected Int, got \(value)")
    }
    return intValue
}

func cleanUnicode(_ s: String) -> String {
    s.replacingOccurrences(
        of: "[\u{200e}\u{200f}\u{200b}\u{200c}\u{200d}\u{2066}\u{2067}\u{2068}\u{2069}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}]",
        with: "", options: .regularExpression)
}

// MARK: - WhatsApp Helpers

let whatsAppBundleID = "net.whatsapp.WhatsApp"

func getWhatsAppPid() -> pid_t? {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: whatsAppBundleID)
    return apps.first?.processIdentifier
}

func launchWhatsApp() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "WhatsApp.app"]
    try process.run()
    process.waitUntilExit()
}

func quitWhatsApp() {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: whatsAppBundleID)
    for app in apps {
        app.terminate()
    }
}

func ensureWhatsAppRunning() throws -> pid_t {
    if let pid = getWhatsAppPid() { return pid }
    try launchWhatsApp()
    Thread.sleep(forTimeInterval: 2.0)
    guard let pid = getWhatsAppPid() else {
        throw MCPError.internalError("Failed to launch WhatsApp")
    }
    return pid
}

func activateWhatsApp(pid: pid_t) {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: whatsAppBundleID)
    apps.first?.activate(options: [.activateIgnoringOtherApps])
    Thread.sleep(forTimeInterval: 0.3)
}

// MARK: - Accessibility Tree Helpers

struct AXElementInfo {
    let role: String
    let description: String?
    let value: String?
    let title: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    /// Best available text from any attribute
    var bestText: String {
        let d = cleanUnicode(description ?? "")
        if !d.isEmpty { return d }
        let t = cleanUnicode(title ?? "")
        if !t.isEmpty { return t }
        let v = cleanUnicode(value ?? "")
        return v
    }
}

func traverseAXTree(pid: pid_t, maxDepth: Int = 15) -> [AXElementInfo] {
    let appElement = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appElement, 5.0)
    var results: [AXElementInfo] = []

    func traverse(_ element: AXUIElement, depth: Int) {
        guard depth < maxDepth else { return }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        let desc = descRef as? String

        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let value = valueRef as? String

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)

        var pos = CGPoint.zero
        var size = CGSize.zero
        if let posRef = posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) }
        if let sizeRef = sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }

        let hasText = (desc != nil && !desc!.isEmpty) || (value != nil && !value!.isEmpty) || (title != nil && !title!.isEmpty)
        if hasText || ["AXButton", "AXTextField", "AXTextArea", "AXStaticText", "AXHeading", "AXGenericElement", "AXLink"].contains(role) {
            results.append(AXElementInfo(
                role: role,
                description: desc,
                value: value,
                title: title,
                x: pos.x,
                y: pos.y,
                width: size.width,
                height: size.height
            ))
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            traverse(child, depth: depth + 1)
        }
    }

    traverse(appElement, depth: 0)
    return results
}

func findElement(in elements: [AXElementInfo], text: String, role: String? = nil) -> AXElementInfo? {
    let query = text.lowercased()
    return elements.first { el in
        if let role = role, el.role != role { return false }
        let desc = (el.description ?? "").lowercased()
        let val = (el.value ?? "").lowercased()
        let ttl = (el.title ?? "").lowercased()
        return desc.contains(query) || val.contains(query) || ttl.contains(query)
    }
}

func findElements(in elements: [AXElementInfo], role: String) -> [AXElementInfo] {
    return elements.filter { $0.role == role }
}

// MARK: - Click / Type / Key Helpers

func saveCursorPosition() -> CGPoint? {
    let nsPos = NSEvent.mouseLocation
    guard let primaryScreen = NSScreen.screens.first else { return nil }
    return CGPoint(x: nsPos.x, y: primaryScreen.frame.height - nsPos.y)
}

func restoreCursorPosition(_ pos: CGPoint) {
    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: pos, mouseButton: .left) {
        moveEvent.post(tap: .cghidEventTap)
    }
}

func clickAt(x: Double, y: Double) {
    let savedPos = saveCursorPosition()
    let point = CGPoint(x: x, y: y)
    let source = CGEventSource(stateID: .hidSystemState)
    let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    mouseDown?.post(tap: .cghidEventTap)
    mouseUp?.post(tap: .cghidEventTap)
    if let savedPos = savedPos {
        restoreCursorPosition(savedPos)
    }
}

func clickElement(_ el: AXElementInfo) {
    clickAt(x: el.x + el.width / 2, y: el.y + el.height / 2)
}

func pasteText(_ text: String) -> Bool {
    let pb = NSPasteboard.general
    let backup = pb.string(forType: .string)
    pb.clearContents()
    guard pb.setString(text, forType: .string) else { return false }
    sendKeyEvent(keyCode: 9, flags: .maskCommand) // Cmd+V
    Thread.sleep(forTimeInterval: 0.35)
    pb.clearContents()
    if let backup = backup {
        _ = pb.setString(backup, forType: .string)
    }
    return true
}

func sendKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    if flags.isEmpty {
        for code: CGKeyCode in [55, 56, 58, 59] {
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            up?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    if !flags.isEmpty {
        down?.flags = flags
        up?.flags = flags
    }
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    if !flags.isEmpty {
        for code: CGKeyCode in [55, 56, 58, 59] {
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            up?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

func pressReturn() { sendKeyEvent(keyCode: 36) }
func pressEscape() { sendKeyEvent(keyCode: 53) }

func scrollAt(x: Double, y: Double, deltaY: Int32) {
    let savedPos = saveCursorPosition()
    // Move mouse to scroll location
    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) {
        moveEvent.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.1)
    // Send scroll event
    if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) {
        scrollEvent.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.3)
    if let savedPos = savedPos {
        restoreCursorPosition(savedPos)
    }
}

// MARK: - Codable Response Types

struct ChatInfo: Codable {
    let name: String
    let lastMessage: String?
    let unreadCount: Int
}

struct MessageInfo: Codable {
    let sender: String
    let text: String
    let time: String
    let isFromMe: Bool
}

struct StatusInfo: Codable {
    let whatsappRunning: Bool
    let pid: Int?
    let accessibilityTrusted: Bool
}

struct SearchResult: Codable {
    let index: Int
    let section: String        // "chats", "contacts", or "media"
    let contactName: String?   // parsed contact name (may be nil if not extractable)
    let rawDescription: String // full raw AX description
    let preview: String?       // message preview (for chat results)
    let time: String?          // timestamp if found
}

struct ActiveChatInfo: Codable {
    let name: String?
    let subtitle: String?
    let recentMessages: [MessageInfo]?
}

// MARK: - Search Result Parser

/// Parses WhatsApp button descriptions into structured fields.
/// Patterns observed:
///   Sent: "Your message, {text}, {time}, Sent to {name}, {status} {name} Double tap..."
///   Received: "message, {text}, {time}, {name} Double tap..."
///   Group received: "Message from {sender}, {text}, {time}, Received in {name}, {count} unread..."
///   Added: "Added by non-contact {name}, {count} unread messages..."
///   Contact: Just "{name}" (short, no commas with message pattern)
struct ParsedSearchResult {
    var contactName: String?
    var preview: String?
    var time: String?
}

func parseButtonDescription(_ raw: String) -> ParsedSearchResult {
    var result = ParsedSearchResult()
    let text = raw.trimmingCharacters(in: .whitespaces)

    // Pattern: "Sent to {name}" — extract name after "Sent to"
    if let sentRange = text.range(of: #"Sent to ([^,]+)"#, options: .regularExpression) {
        let match = String(text[sentRange])
        result.contactName = match.replacingOccurrences(of: "Sent to ", with: "").trimmingCharacters(in: .whitespaces)
    }

    // Pattern: "Received in {name}" (groups)
    if result.contactName == nil, let recvRange = text.range(of: #"Received in ([^,]+)"#, options: .regularExpression) {
        let match = String(text[recvRange])
        result.contactName = match.replacingOccurrences(of: "Received in ", with: "").trimmingCharacters(in: .whitespaces)
    }

    // Pattern: "Received from {name}"
    if result.contactName == nil, let recvRange = text.range(of: #"Received from ([^,]+)"#, options: .regularExpression) {
        let match = String(text[recvRange])
        result.contactName = match.replacingOccurrences(of: "Received from ", with: "").trimmingCharacters(in: .whitespaces)
    }

    // Pattern: "Added by non-contact {name}, N unread"
    if result.contactName == nil, let addedRange = text.range(of: #"Added by non-contact ([^,]+)"#, options: .regularExpression) {
        let match = String(text[addedRange])
        result.contactName = match.replacingOccurrences(of: "Added by non-contact ", with: "").trimmingCharacters(in: .whitespaces)
    }

    // If no pattern matched but text is short (< 60 chars) and doesn't start with "message," or "Your message," — treat as contact name
    if result.contactName == nil {
        let lower = text.lowercased()
        if !lower.hasPrefix("message,") && !lower.hasPrefix("your message,") && !lower.hasPrefix("added by") {
            // Likely a plain contact name or group name
            // Strip "Double tap..." suffix if present
            if let dtRange = text.range(of: "Double tap", options: .caseInsensitive) {
                let before = String(text[text.startIndex..<dtRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !before.isEmpty {
                    result.contactName = before
                }
            } else {
                result.contactName = text
            }
        }
    }

    // Extract time: pattern like "1:23 PM" or "12:34" within the text
    if let timeMatch = text.range(of: #"\d{1,2}:\d{2}\s*[APap][Mm]"#, options: .regularExpression) {
        result.time = String(text[timeMatch]).trimmingCharacters(in: .whitespaces)
    } else if let timeMatch24 = text.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) {
        result.time = String(text[timeMatch24]).trimmingCharacters(in: .whitespaces)
    }

    // Extract preview: for "Your message, {text}," or "message, {text}," or "Message from {sender}, {text},"
    if text.hasPrefix("Your message, ") {
        let rest = String(text.dropFirst("Your message, ".count))
        // Take everything up to the time
        if let timeStr = result.time, let timeRange = rest.range(of: timeStr) {
            result.preview = String(rest[rest.startIndex..<timeRange.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        }
    } else if text.hasPrefix("message, ") {
        let rest = String(text.dropFirst("message, ".count))
        if let timeStr = result.time, let timeRange = rest.range(of: timeStr) {
            result.preview = String(rest[rest.startIndex..<timeRange.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        }
    } else if text.hasPrefix("Message from ") {
        // "Message from {sender}, {text}, {time}, ..."
        let rest = String(text.dropFirst("Message from ".count))
        // Skip sender (up to first comma)
        if let firstComma = rest.firstIndex(of: ",") {
            let afterSender = String(rest[rest.index(after: firstComma)...]).trimmingCharacters(in: .whitespaces)
            if let timeStr = result.time, let timeRange = afterSender.range(of: timeStr) {
                result.preview = String(afterSender[afterSender.startIndex..<timeRange.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            }
        }
    }

    // Clean up: strip "Delivered", "Read", "Sent" status from contactName
    if let name = result.contactName {
        var cleaned = name
        for suffix in ["Delivered", "Read", "Sent", "Pending"] {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            }
        }
        // Strip "Double tap..." suffix
        if let dtRange = cleaned.range(of: "Double tap", options: .caseInsensitive) {
            cleaned = String(cleaned[cleaned.startIndex..<dtRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        result.contactName = cleaned.isEmpty ? nil : cleaned
    }

    return result
}

// MARK: - Shared: get active chat info from heading

let sectionHeaders: Set<String> = ["chats", "other contacts", "contacts", "media", "today", "yesterday"]

struct ChatHeadingInfo {
    var name: String?
    var subtitle: String?  // "online", "last seen today at 6:32 PM", "typing..."
}

func getActiveChatHeading(elements: [AXElementInfo]) -> ChatHeadingInfo {
    var info = ChatHeadingInfo()
    let headings = findElements(in: elements, role: "AXHeading")

    // Find the chat panel heading (x > 1750, not a section header)
    for h in headings {
        let raw = cleanUnicode(h.description ?? h.title ?? "")
        if raw.isEmpty { continue }
        let lower = raw.lowercased()
        if sectionHeaders.contains(lower) { continue }
        if h.x > 1750 {
            // Heading may contain "last seen today at 6:32 PM Nhat" or "online Nhat"
            if let range = raw.range(of: #"^(last seen .+?|online|typing\.\.\.)\s+"#, options: .regularExpression) {
                info.subtitle = String(raw[raw.startIndex..<range.upperBound]).trimmingCharacters(in: .whitespaces)
                let name = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { info.name = name }
            } else {
                info.name = raw.trimmingCharacters(in: .whitespaces)
            }
            return info
        }
    }

    // Fallback: any heading that's not a section header
    for h in headings {
        let raw = cleanUnicode(h.description ?? h.title ?? "")
        if raw.isEmpty { continue }
        let lower = raw.lowercased()
        if sectionHeaders.contains(lower) { continue }
        if let range = raw.range(of: #"^(last seen .+?|online|typing\.\.\.)\s+"#, options: .regularExpression) {
            info.subtitle = String(raw[raw.startIndex..<range.upperBound]).trimmingCharacters(in: .whitespaces)
            let name = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { info.name = name }
        } else {
            info.name = raw.trimmingCharacters(in: .whitespaces)
        }
        return info
    }

    return info
}

/// Convenience: just the name
func getActiveChatName(pid: pid_t) -> String? {
    let elements = traverseAXTree(pid: pid)
    return getActiveChatHeading(elements: elements).name
}

/// Parse messages from elements (shared between handleReadMessages and handleGetActiveChat)
func parseMessages(from elements: [AXElementInfo], limit: Int) -> [MessageInfo] {
    var messages: [MessageInfo] = []
    let genericElements = findElements(in: elements, role: "AXGenericElement")
    for el in genericElements {
        let desc = cleanUnicode(el.description ?? "")
        if desc.isEmpty { continue }
        if desc.hasPrefix("message, ") || desc.hasPrefix("Your message, ") {
            let isFromMe = desc.hasPrefix("Your message, ")
            let prefix = isFromMe ? "Your message, " : "message, "
            let rest = String(desc.dropFirst(prefix.count))
            var sender = ""
            var time = ""
            var text = rest
            if let receivedRange = rest.range(of: #",\s+Received from (.+)$"#, options: .regularExpression) {
                let receivedPart = String(rest[receivedRange])
                sender = receivedPart.replacingOccurrences(of: #"^,\s+Received from "#, with: "", options: .regularExpression)
                text = String(rest[rest.startIndex..<receivedRange.lowerBound])
            } else if let sentRange = rest.range(of: #",\s+Sent to (.+)$"#, options: .regularExpression) {
                let sentPart = String(rest[sentRange])
                sender = sentPart.replacingOccurrences(of: #"^,\s+Sent to "#, with: "", options: .regularExpression)
                text = String(rest[rest.startIndex..<sentRange.lowerBound])
            }
            if let timeRange = text.range(of: #",\s+\d{1,2}:\d{2}\s*[APap][Mm]?$"#, options: .regularExpression) {
                time = String(text[timeRange]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                text = String(text[text.startIndex..<timeRange.lowerBound])
            } else if let timeRange24 = text.range(of: #",\s+\d{1,2}:\d{2}$"#, options: .regularExpression) {
                time = String(text[timeRange24]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                text = String(text[text.startIndex..<timeRange24.lowerBound])
            }
            messages.append(MessageInfo(
                sender: isFromMe ? "me" : sender.trimmingCharacters(in: .whitespaces),
                text: text.trimmingCharacters(in: .whitespaces),
                time: time,
                isFromMe: isFromMe
            ))
        }
    }
    return Array(messages.suffix(limit))
}

// MARK: - Search Result Button Filtering

let uiSkipKeywords: Set<String> = [
    "chats", "calls", "updates", "settings", "search", "back", "close",
    "all", "unread", "favorites", "groups", "new chat", "clear text",
    "more info", "archived", "starred", "send", "share media",
    "voice message", "video message", "start video call", "start voice call",
    "photos", "gifs", "links", "videos", "documents", "audio", "polls", "events",
    "new group", "new community"
]

/// Minimum x position for search result buttons (sidebar area)
let searchResultMinX: Double = 1350

/// Minimum width for search result buttons
let searchResultMinWidth: Double = 200

func isSearchResultButton(_ btn: AXElementInfo) -> Bool {
    guard btn.x >= searchResultMinX, btn.width >= searchResultMinWidth else { return false }
    let text = btn.bestText.lowercased()
    if text.isEmpty { return false }
    if uiSkipKeywords.contains(text) { return false }
    // Skip tab filter buttons like "1 of 4 All..."
    if text.range(of: #"^\d+ of \d+"#, options: .regularExpression) != nil { return false }
    // Skip hex ID buttons
    if text.range(of: #"^[0-9A-Fa-f ]{20,}$"#, options: .regularExpression) != nil { return false }
    return true
}

// MARK: - Accessibility Guard

/// Check accessibility and return a clear, actionable error if not granted.
/// Call this at the top of every tool that uses AX APIs or CGEvent posting.
func requireAccessibility() -> String? {
    let trusted = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary
    )
    if trusted { return nil }
    return serializeToJsonString([
        "error": "Accessibility permission not granted. The user must enable it in System Settings > Privacy & Security > Accessibility for the app running this MCP server. Without this permission, WhatsApp cannot be controlled.",
        "fix": "Open System Settings > Privacy & Security > Accessibility and toggle ON the app that hosts whatsapp-mcp (e.g. Fazm, Claude Code, or Terminal).",
        "accessibilityTrusted": "false"
    ]) ?? "{\"error\": \"Accessibility permission not granted.\"}"
}

/// Functional probe: actually try to read the AX tree and verify we get elements back.
/// AXIsProcessTrusted can return true while AX calls silently fail (stale TCC cache).
func probeAccessibility(pid: pid_t) -> Bool {
    let appElement = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appElement, 2.0)
    var childrenRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenRef)
    return result == .success && childrenRef != nil
}

// MARK: - Tool Implementations

func handleStatus() -> String {
    let pid = getWhatsAppPid()
    let trusted = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary
    )
    // If TCC says trusted and WhatsApp is running, do a functional probe
    var functionallyWorking: Bool? = nil
    if trusted, let pid = pid {
        functionallyWorking = probeAccessibility(pid: pid)
    }
    let status: [String: String] = [
        "whatsappRunning": pid != nil ? "true" : "false",
        "pid": pid.map { "\($0)" } ?? "null",
        "accessibilityTrusted": trusted ? "true" : "false",
        "accessibilityWorking": functionallyWorking.map { $0 ? "true" : "false" } ?? "null"
    ]
    if trusted && functionallyWorking == false {
        var s = status
        s["warning"] = "Accessibility reports trusted but AX calls are failing. This is common after macOS updates or app re-signing. Try removing and re-adding the app in System Settings > Privacy & Security > Accessibility, then restart the app."
        return serializeToJsonString(s) ?? "{\"error\": \"serialization failed\"}"
    }
    return serializeToJsonString(status) ?? "{\"error\": \"serialization failed\"}"
}

func handleStart() -> String {
    if let pid = getWhatsAppPid() {
        return "{\"success\": true, \"already_running\": true, \"pid\": \(pid)}"
    }
    do {
        try launchWhatsApp()
        Thread.sleep(forTimeInterval: 2.0)
        if let pid = getWhatsAppPid() {
            return "{\"success\": true, \"already_running\": false, \"pid\": \(pid)}"
        }
        return "{\"success\": false, \"error\": \"WhatsApp did not start\"}"
    } catch {
        return "{\"success\": false, \"error\": \"\(error.localizedDescription)\"}"
    }
}

func handleQuit() -> String {
    guard getWhatsAppPid() != nil else {
        return "{\"success\": true, \"was_running\": false}"
    }
    quitWhatsApp()
    // Wait up to 5 seconds for graceful quit
    for _ in 0..<10 {
        Thread.sleep(forTimeInterval: 0.5)
        if getWhatsAppPid() == nil {
            return "{\"success\": true, \"was_running\": true}"
        }
    }
    // Force quit if still running
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: whatsAppBundleID)
    for app in apps {
        app.forceTerminate()
    }
    Thread.sleep(forTimeInterval: 1.0)
    let stillRunning = getWhatsAppPid() != nil
    return "{\"success\": \(!stillRunning), \"was_running\": true, \"force_quit\": true}"
}

func handleGetActiveChat(args: [String: Value]?) throws -> String {
    if let err = requireAccessibility() { return err }
    let pid = try ensureWhatsAppRunning()
    let elements = traverseAXTree(pid: pid)
    let heading = getActiveChatHeading(elements: elements)
    let limit = (try? getOptionalInt(from: args, key: "limit")) ?? 10
    let messages = heading.name != nil ? parseMessages(from: elements, limit: limit) : nil
    let info = ActiveChatInfo(name: heading.name, subtitle: heading.subtitle, recentMessages: messages)
    return serializeToJsonString(info) ?? "{\"name\": null}"
}

func handleListChats(args: [String: Value]?) throws -> String {
    if let err = requireAccessibility() { return err }
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.5)

    let filter = getOptionalString(from: args, key: "filter")
    if let filter = filter, filter != "all" {
        let elements = traverseAXTree(pid: pid)
        let filterName: String
        switch filter.lowercased() {
        case "unread": filterName = "Unread"
        case "favorites": filterName = "Favorites"
        case "groups": filterName = "Groups"
        default: filterName = "All"
        }
        if let filterBtn = findElement(in: elements, text: filterName, role: "AXButton") {
            clickElement(filterBtn)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    let elements = traverseAXTree(pid: pid)
    var chats: [ChatInfo] = []
    let buttons = findElements(in: elements, role: "AXButton")

    for btn in buttons {
        let cleanDesc = cleanUnicode(btn.description ?? "")
        if cleanDesc.isEmpty { continue }
        let descLower = cleanDesc.lowercased()
        if uiSkipKeywords.contains(descLower) { continue }
        if descLower.hasPrefix("start ") { continue }

        var unread = 0
        var name = cleanDesc
        if let range = cleanDesc.range(of: #",\s*(\d+)\s+unread"#, options: .regularExpression) {
            let match = cleanDesc[range]
            if let numMatch = match.range(of: #"\d+"#, options: .regularExpression) {
                unread = Int(match[numMatch]) ?? 0
            }
            name = String(cleanDesc[cleanDesc.startIndex..<range.lowerBound])
        }

        if name.count < 2 { continue }
        if name.range(of: #"^[0-9A-F ]{20,}$"#, options: .regularExpression) != nil { continue }

        let cleanVal = cleanUnicode(btn.value ?? "")
        chats.append(ChatInfo(
            name: name.trimmingCharacters(in: .whitespaces),
            lastMessage: cleanVal.isEmpty ? nil : cleanVal,
            unreadCount: unread
        ))
    }

    return serializeToJsonString(chats) ?? "[]"
}

// whatsapp_search: types query into sidebar search, returns indexed results, leaves search OPEN
func handleSearch(args: [String: Value]?) throws -> String {
    if let err = requireAccessibility() { return err }
    let query = try getRequiredString(from: args, key: "query")
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.5)

    let elements = traverseAXTree(pid: pid)
    guard let searchField = findElement(in: elements, text: "Search", role: "AXStaticText") else {
        return "{\"error\": \"Could not find search field\"}"
    }

    clickElement(searchField)
    Thread.sleep(forTimeInterval: 0.3)
    // Select all existing text (Cmd+A) then replace with new query
    sendKeyEvent(keyCode: 0, flags: .maskCommand)  // Cmd+A
    Thread.sleep(forTimeInterval: 0.1)
    _ = pasteText(query)
    Thread.sleep(forTimeInterval: 1.5)

    let resultElements = traverseAXTree(pid: pid)
    let results = parseVisibleSearchResults(from: resultElements)

    fputs("log: handleSearch: query='\(query)', found \(results.count) results\n", stderr)

    // NOTE: search is left OPEN so caller can use whatsapp_open_chat with an index
    return serializeToJsonString(results) ?? "[]"
}

// whatsapp_open_chat: clicks the Nth search result (call whatsapp_search first), then reports active chat
func handleOpenChat(args: [String: Value]?) throws -> String {
    if let err = requireAccessibility() { return err }
    let index = (try getOptionalInt(from: args, key: "index")) ?? 0
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.3)

    let elements = traverseAXTree(pid: pid)

    // Get section headings to filter results
    let headings = findElements(in: elements, role: "AXHeading")
    var chatsHeadingY: Double? = nil
    var contactsHeadingY: Double? = nil
    var mediaHeadingY: Double? = nil
    for h in headings {
        let text = cleanUnicode(h.description ?? h.title ?? "").lowercased()
        if text == "chats" && h.x >= searchResultMinX { chatsHeadingY = h.y }
        if text.contains("contact") && h.x >= searchResultMinX { contactsHeadingY = h.y }
        if text == "media" && h.x >= searchResultMinX { mediaHeadingY = h.y }
    }

    let firstSectionY = [chatsHeadingY, contactsHeadingY].compactMap { $0 }.min()
    let buttons = findElements(in: elements, role: "AXButton")
    var candidates: [AXElementInfo] = []
    for btn in buttons {
        guard isSearchResultButton(btn) else { continue }
        if let firstY = firstSectionY, btn.y < firstY { continue }
        if let mediaY = mediaHeadingY, btn.y >= mediaY { continue }
        candidates.append(btn)
    }
    candidates.sort { $0.y < $1.y }

    guard index < candidates.count else {
        pressEscape()
        return "{\"success\": false, \"error\": \"Index \(index) out of range. Found \(candidates.count) results.\", \"active_chat\": null}"
    }

    let target = candidates[index]
    let targetDesc = cleanUnicode(target.bestText)
    fputs("log: clicking result \(index): '\(targetDesc.prefix(80))' at (\(target.x),\(target.y))\n", stderr)
    clickElement(target)
    Thread.sleep(forTimeInterval: 1.0)

    let activeName = getActiveChatName(pid: pid)
    return "{\"success\": true, \"clicked_description\": \"\(targetDesc.prefix(80).replacingOccurrences(of: "\"", with: "\\\""))\", \"active_chat\": \"\(activeName ?? "unknown")\"}"
}

// Parse visible search results from an already-traversed AX tree
func parseVisibleSearchResults(from elements: [AXElementInfo]) -> [SearchResult] {
    let headings = findElements(in: elements, role: "AXHeading")
    var chatsHeadingY: Double? = nil
    var contactsHeadingY: Double? = nil
    var mediaHeadingY: Double? = nil
    for h in headings {
        let text = cleanUnicode(h.description ?? h.title ?? "").lowercased()
        if text == "chats" && h.x >= searchResultMinX { chatsHeadingY = h.y }
        if text.contains("contact") && h.x >= searchResultMinX { contactsHeadingY = h.y }
        if text == "media" && h.x >= searchResultMinX { mediaHeadingY = h.y }
    }

    let firstSectionY = [chatsHeadingY, contactsHeadingY].compactMap { $0 }.min()
    let buttons = findElements(in: elements, role: "AXButton")
    var candidates: [(btn: AXElementInfo, section: String)] = []

    for btn in buttons {
        guard isSearchResultButton(btn) else { continue }
        if let firstY = firstSectionY, btn.y < firstY { continue }
        if let mediaY = mediaHeadingY, btn.y >= mediaY { continue }

        var section = "chats"
        if let contactsY = contactsHeadingY, btn.y >= contactsY { section = "contacts" }
        else if let chatsY = chatsHeadingY, btn.y >= chatsY { section = "chats" }

        candidates.append((btn: btn, section: section))
    }

    candidates.sort { $0.btn.y < $1.btn.y }

    var results: [SearchResult] = []
    for (idx, entry) in candidates.enumerated() {
        let rawDesc = cleanUnicode(entry.btn.bestText)
        let parsed = parseButtonDescription(rawDesc)

        results.append(SearchResult(
            index: idx,
            section: entry.section,
            contactName: parsed.contactName,
            rawDescription: String(rawDesc.prefix(200)),
            preview: parsed.preview.map { String($0.prefix(150)) },
            time: parsed.time
        ))
    }
    return results
}

// whatsapp_scroll_search: scroll within search results to load more
func handleScrollSearch(args: [String: Value]?) throws -> String {
    if let err = requireAccessibility() { return err }
    let direction = getOptionalString(from: args, key: "direction") ?? "down"
    let amount = (try getOptionalInt(from: args, key: "amount")) ?? 3
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.3)

    // Find the search results area (buttons in sidebar)
    let elements = traverseAXTree(pid: pid)
    let buttons = findElements(in: elements, role: "AXButton").filter { isSearchResultButton($0) }

    guard let firstBtn = buttons.first else {
        return "{\"success\": false, \"error\": \"No search results visible to scroll\"}"
    }

    // Scroll in the center of the visible results list
    let lastBtn = buttons.last ?? firstBtn
    let scrollX = firstBtn.x + firstBtn.width / 2
    let scrollY = (firstBtn.y + lastBtn.y) / 2  // midpoint of visible results
    let delta: Int32 = direction == "up" ? Int32(amount) : -Int32(amount)

    // Scroll multiple times for reliability (WhatsApp lazy-loads incrementally)
    for _ in 0..<3 {
        scrollAt(x: scrollX, y: scrollY, deltaY: delta)
        Thread.sleep(forTimeInterval: 0.3)
    }
    Thread.sleep(forTimeInterval: 0.3)

    // Return full parsed results after scrolling
    let newElements = traverseAXTree(pid: pid)
    let results = parseVisibleSearchResults(from: newElements)
    return serializeToJsonString(results) ?? "[]"
}

func handleReadMessages(args: [String: Value]?) throws -> String {
    if let err = requireAccessibility() { return err }
    let pid = try ensureWhatsAppRunning()
    let limit = (try getOptionalInt(from: args, key: "limit")) ?? 20
    let elements = traverseAXTree(pid: pid)
    let messages = parseMessages(from: elements, limit: limit)
    return serializeToJsonString(messages) ?? "[]"
}

// whatsapp_send_message: sends a message in the CURRENTLY OPEN chat (no searching)
func handleSendMessage(args: [String: Value]?) throws -> String {
    if let err = requireAccessibility() { return err }
    let message = try getRequiredString(from: args, key: "message")
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.3)

    // Verify there's an active chat
    guard let activeName = getActiveChatName(pid: pid), !activeName.isEmpty else {
        return "{\"success\": false, \"error\": \"No chat is currently open. Use whatsapp_search + whatsapp_open_chat first.\"}"
    }

    let elements = traverseAXTree(pid: pid)
    let textAreas = findElements(in: elements, role: "AXTextArea")
    let composeField = textAreas.first(where: {
        ($0.description ?? "").lowercased().contains("compose") ||
        ($0.description ?? "").lowercased().contains("message") ||
        ($0.description ?? "").lowercased().contains("type")
    }) ?? textAreas.last

    guard let compose = composeField else {
        return "{\"success\": false, \"error\": \"Could not find compose message field\"}"
    }

    clickElement(compose)
    Thread.sleep(forTimeInterval: 0.3)

    guard pasteText(message) else {
        return "{\"success\": false, \"error\": \"Failed to paste message text\"}"
    }
    Thread.sleep(forTimeInterval: 0.3)

    pressReturn()
    Thread.sleep(forTimeInterval: 1.0)

    // Post-send verification: check if last message in chat matches what we sent
    let postElements = traverseAXTree(pid: pid)
    let genericElements = findElements(in: postElements, role: "AXGenericElement")

    var lastSentMessage: String? = nil
    for el in genericElements {
        let desc = cleanUnicode(el.description ?? "")
        if desc.hasPrefix("Your message, ") {
            // Extract just the message text
            let rest = String(desc.dropFirst("Your message, ".count))
            // Strip time and "Sent to..." suffix
            var text = rest
            if let timeRange = text.range(of: #",\s+\d{1,2}:\d{2}\s*[APap][Mm]"#, options: .regularExpression) {
                text = String(text[text.startIndex..<timeRange.lowerBound])
            }
            lastSentMessage = text.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        }
    }

    let verified: Bool
    let escapedMessage = message.prefix(100).replacingOccurrences(of: "\"", with: "\\\"")
    if let lastSent = lastSentMessage {
        // Check if our message appears in the last sent message (handles emoji/unicode differences)
        let sentNormalized = lastSent.lowercased().trimmingCharacters(in: .whitespaces)
        let msgNormalized = message.lowercased().trimmingCharacters(in: .whitespaces)
        verified = sentNormalized.hasPrefix(msgNormalized) || msgNormalized.hasPrefix(sentNormalized) || sentNormalized.contains(msgNormalized)
    } else {
        verified = false
    }

    if verified {
        return "{\"success\": true, \"verified\": true, \"to\": \"\(activeName)\", \"message\": \"\(escapedMessage)\"}"
    } else {
        return "{\"success\": true, \"verified\": false, \"to\": \"\(activeName)\", \"message\": \"\(escapedMessage)\", \"warning\": \"Could not verify message appeared in chat. Last sent message: \(lastSentMessage?.prefix(80).replacingOccurrences(of: "\"", with: "\\\"") ?? "none found")\"}"
    }
}

func handleNavigate(args: [String: Value]?) throws -> String {
    if let err = requireAccessibility() { return err }
    let tab = try getRequiredString(from: args, key: "tab")
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.3)

    let elements = traverseAXTree(pid: pid)
    let tabName: String
    switch tab.lowercased() {
    case "chats": tabName = "Chats"
    case "calls": tabName = "Calls"
    case "updates": tabName = "Updates"
    case "settings": tabName = "Settings"
    case "archived": tabName = "Archived"
    case "starred": tabName = "Starred"
    default: tabName = tab
    }

    if let tabBtn = findElement(in: elements, text: tabName, role: "AXButton") {
        clickElement(tabBtn)
        Thread.sleep(forTimeInterval: 0.5)
        return "{\"success\": true, \"tab\": \"\(tabName)\"}"
    }

    return "{\"success\": false, \"error\": \"Tab not found: \(tabName)\"}"
}

// MARK: - MCP Server Setup

func setupAndStartServer() async throws -> Server {
    fputs("log: setupAndStartServer: entering function.\n", stderr)

    let statusTool = Tool(
        name: "whatsapp_status",
        description: "Check if WhatsApp is running and accessibility is granted.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    )

    let startTool = Tool(
        name: "whatsapp_start",
        description: "Launch WhatsApp if not already running. Returns PID.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    )

    let quitTool = Tool(
        name: "whatsapp_quit",
        description: "Quit/close WhatsApp.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    )

    let getActiveChatTool = Tool(
        name: "whatsapp_get_active_chat",
        description: "Returns the name of the currently open/active WhatsApp chat. Use this to verify which chat is open before sending a message.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    )

    let listChatsTool = Tool(
        name: "whatsapp_list_chats",
        description: "List visible chats in WhatsApp sidebar with names, last message preview, and unread count.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "filter": .object([
                    "type": .string("string"),
                    "description": .string("Optional filter: 'all', 'unread', 'favorites', or 'groups'. Default: 'all'"),
                    "enum": .array([.string("all"), .string("unread"), .string("favorites"), .string("groups")])
                ])
            ])
        ])
    )

    let searchTool = Tool(
        name: "whatsapp_search",
        description: """
        Search WhatsApp contacts/chats. Returns structured results with: index, section (chats/contacts), contactName, rawDescription, preview, time.
        Leaves search OPEN — call whatsapp_open_chat(index) to select a result.
        If the contact you want isn't visible, use whatsapp_scroll_search to load more results.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "description": .string("Search query text")])
            ]),
            "required": .array([.string("query")])
        ])
    )

    let openChatTool = Tool(
        name: "whatsapp_open_chat",
        description: "Click the Nth search result to open that chat. Call whatsapp_search first, then use the index from the results. Returns the name of the chat that was actually opened — verify this matches your intended contact.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "index": .object(["type": .string("integer"), "description": .string("0-based index of the search result to click. Default: 0 (first result)")])
            ])
        ])
    )

    let scrollSearchTool = Tool(
        name: "whatsapp_scroll_search",
        description: "Scroll within the search results list to load more results. Use after whatsapp_search if the desired contact isn't visible.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "direction": .object(["type": .string("string"), "description": .string("Scroll direction: 'up' or 'down'. Default: 'down'"), "enum": .array([.string("up"), .string("down")])]),
                "amount": .object(["type": .string("integer"), "description": .string("Number of scroll lines. Default: 3")])
            ])
        ])
    )

    let readMessagesTool = Tool(
        name: "whatsapp_read_messages",
        description: "Read messages from the currently open WhatsApp chat. Returns sender, text, time, and isFromMe for each message.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object(["type": .string("integer"), "description": .string("Max messages to return (default 20)")])
            ])
        ])
    )

    let sendMessageTool = Tool(
        name: "whatsapp_send_message",
        description: "Send a message in the CURRENTLY OPEN chat. Does NOT search or navigate — it only types and sends. Use whatsapp_search + whatsapp_open_chat + whatsapp_get_active_chat to verify the right chat first.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "message": .object(["type": .string("string"), "description": .string("Message text to send")])
            ]),
            "required": .array([.string("message")])
        ])
    )

    let navigateTool = Tool(
        name: "whatsapp_navigate",
        description: "Switch WhatsApp tabs/views (chats, calls, updates, settings, archived, starred).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "tab": .object([
                    "type": .string("string"),
                    "description": .string("Tab to navigate to"),
                    "enum": .array([.string("chats"), .string("calls"), .string("updates"), .string("settings"), .string("archived"), .string("starred")])
                ])
            ]),
            "required": .array([.string("tab")])
        ])
    )

    let allTools = [statusTool, startTool, quitTool, getActiveChatTool, listChatsTool, searchTool, openChatTool, scrollSearchTool, readMessagesTool, sendMessageTool, navigateTool]
    fputs("log: setupAndStartServer: defined \(allTools.count) tools\n", stderr)

    let server = Server(
        name: "WhatsAppMCP",
        version: "3.0.0",
        instructions: """
        WhatsApp MCP server for macOS. Controls the native WhatsApp Catalyst app via accessibility APIs.
        Tools: whatsapp_status, whatsapp_start, whatsapp_quit, whatsapp_get_active_chat, whatsapp_list_chats, whatsapp_search, whatsapp_open_chat, whatsapp_scroll_search, whatsapp_read_messages, whatsapp_send_message, whatsapp_navigate.
        WhatsApp must be installed and accessibility permissions must be granted.

        IMPORTANT workflow for sending messages:
        1. whatsapp_search("contact name") — returns indexed results, leaves search open
        2. whatsapp_open_chat(index: 0) ��� clicks the first result, returns the active chat name
        3. whatsapp_get_active_chat() — verify the correct chat is open
        4. whatsapp_send_message("your message") — sends in the currently open chat

        CRITICAL: If any tool returns an accessibility permission error, do NOT attempt to use WhatsApp Web via a browser as a fallback. Browser automation with WhatsApp Web does not work reliably (contenteditable fields, focus management issues). Instead, tell the user to grant Accessibility permission in System Settings > Privacy & Security > Accessibility for the host app, then retry.

        If accessibilityWorking is false but accessibilityTrusted is true, the TCC database is stale. Tell the user to remove and re-add the app in Accessibility settings, then restart.

        When working with tool results, write down any important information you might need later in your response, as the original tool result may be cleared later.
        """,
        capabilities: .init(tools: .init(listChanged: true))
    )

    await server.withMethodHandler(ReadResource.self) { params in
        return .init(contents: [.text("", uri: params.uri)])
    }
    await server.withMethodHandler(ListResources.self) { _ in
        return ListResources.Result(resources: [])
    }
    await server.withMethodHandler(ListPrompts.self) { _ in
        return ListPrompts.Result(prompts: [])
    }

    await server.withMethodHandler(ListTools.self) { _ in
        fputs("log: handler(ListTools): returning \(allTools.count) tools\n", stderr)
        return ListTools.Result(tools: allTools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        fputs("log: handler(CallTool): tool=\(params.name) args=\(params.arguments?.debugDescription ?? "nil")\n", stderr)

        do {
            let result: String
            switch params.name {
            case "whatsapp_status":
                result = handleStatus()
            case "whatsapp_start":
                result = handleStart()
            case "whatsapp_quit":
                result = handleQuit()
            case "whatsapp_get_active_chat":
                result = try handleGetActiveChat(args: params.arguments)
            case "whatsapp_list_chats":
                result = try handleListChats(args: params.arguments)
            case "whatsapp_search":
                result = try handleSearch(args: params.arguments)
            case "whatsapp_open_chat":
                result = try handleOpenChat(args: params.arguments)
            case "whatsapp_scroll_search":
                result = try handleScrollSearch(args: params.arguments)
            case "whatsapp_read_messages":
                result = try handleReadMessages(args: params.arguments)
            case "whatsapp_send_message":
                result = try handleSendMessage(args: params.arguments)
            case "whatsapp_navigate":
                result = try handleNavigate(args: params.arguments)
            default:
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }
            return .init(content: [.text(result)])
        } catch let error as MCPError {
            throw error
        } catch {
            fputs("error: handler(CallTool): \(error)\n", stderr)
            return .init(content: [.text("{\"error\": \"\(error.localizedDescription)\"}")], isError: true)
        }
    }

    let transport = StdioTransport()
    fputs("log: setupAndStartServer: starting server...\n", stderr)
    try await server.start(transport: transport)
    fputs("log: setupAndStartServer: server started.\n", stderr)
    return server
}

// MARK: - Entry Point

@main
struct WhatsAppMCPServer {
    static func main() async {
        fputs("log: main: starting WhatsApp MCP server.\n", stderr)
        let server: Server
        do {
            server = try await setupAndStartServer()
            await server.waitUntilCompleted()
        } catch {
            fputs("error: main: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }
}
