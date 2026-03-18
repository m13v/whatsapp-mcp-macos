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

func clickAt(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    let source = CGEventSource(stateID: .hidSystemState)
    let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    mouseDown?.post(tap: .cghidEventTap)
    mouseUp?.post(tap: .cghidEventTap)
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
    // Restore clipboard
    pb.clearContents()
    if let backup = backup {
        _ = pb.setString(backup, forType: .string)
    }
    return true
}

func sendKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    // Clear stuck modifiers for unmodified keys
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
        // Release modifiers
        for code: CGKeyCode in [55, 56, 58, 59] {
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            up?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

func pressReturn() {
    sendKeyEvent(keyCode: 36) // Return
}

func pressEscape() {
    sendKeyEvent(keyCode: 53) // Escape
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

// MARK: - Tool Implementations

func handleStatus() -> String {
    let pid = getWhatsAppPid()
    let trusted = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary
    )
    let status = StatusInfo(
        whatsappRunning: pid != nil,
        pid: pid.map { Int($0) },
        accessibilityTrusted: trusted
    )
    return serializeToJsonString(status) ?? "{\"error\": \"serialization failed\"}"
}

func handleListChats(args: [String: Value]?) throws -> String {
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.5)

    let filter = getOptionalString(from: args, key: "filter")

    // If a filter tab is requested, click it first
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

    // Chat entries are AXButton elements in the sidebar with descriptions containing contact names
    // They typically have desc like "Contact Name" or "Contact Name, 3 unread messages"
    // and value like last message text
    var chats: [ChatInfo] = []
    let buttons = findElements(in: elements, role: "AXButton")

    for btn in buttons {
        let desc = btn.description ?? ""
        let val = btn.value ?? ""

        // Strip Unicode directional markers (LTR \u{200e}, RTL \u{200f}, etc.)
        let cleanDesc = desc.replacingOccurrences(of: "[\u{200e}\u{200f}\u{200b}\u{200c}\u{200d}\u{2066}\u{2067}\u{2068}\u{2069}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}]", with: "", options: .regularExpression)
        if cleanDesc.isEmpty { continue }

        // Skip navigation buttons and filter buttons
        let skipKeywords = ["Chats", "Calls", "Updates", "Settings", "New Chat", "Search",
                           "All", "Unread", "Favorites", "Groups", "Archived", "Starred",
                           "Community", "Channels", "Back", "Close", "Menu", "Filter",
                           "More options", "New group", "New community",
                           "Start video call", "Start voice call", "Share media",
                           "Voice message", "Video message"]
        let descLower = cleanDesc.lowercased()
        if skipKeywords.contains(where: { descLower == $0.lowercased() || descLower.hasPrefix($0.lowercased()) }) { continue }

        // Parse unread count from description (e.g. "Contact, 3 unread messages")
        var unread = 0
        var name = cleanDesc
        if let range = cleanDesc.range(of: #",\s*(\d+)\s+unread"#, options: .regularExpression) {
            let match = cleanDesc[range]
            if let numMatch = match.range(of: #"\d+"#, options: .regularExpression) {
                unread = Int(match[numMatch]) ?? 0
            }
            name = String(cleanDesc[cleanDesc.startIndex..<range.lowerBound])
        }

        // Skip entries that look like UI controls (short single words that match known controls)
        if name.count < 2 { continue }
        // Skip hex-looking strings (likely element IDs)
        if name.range(of: #"^[0-9A-F ]{20,}$"#, options: .regularExpression) != nil { continue }

        let cleanVal = val.replacingOccurrences(of: "[\u{200e}\u{200f}\u{200b}\u{200c}\u{200d}\u{2066}\u{2067}\u{2068}\u{2069}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}]", with: "", options: .regularExpression)
        chats.append(ChatInfo(
            name: name.trimmingCharacters(in: .whitespaces),
            lastMessage: cleanVal.isEmpty ? nil : cleanVal,
            unreadCount: unread
        ))
    }

    return serializeToJsonString(chats) ?? "[]"
}

func handleOpenChat(args: [String: Value]?) throws -> String {
    let name = try getRequiredString(from: args, key: "name")
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.5)

    let elements = traverseAXTree(pid: pid)

    // Try to find the chat button by name
    if let chatBtn = findElement(in: elements, text: name, role: "AXButton") {
        clickElement(chatBtn)
        Thread.sleep(forTimeInterval: 0.8)

        // Verify by checking for heading with the name
        let newElements = traverseAXTree(pid: pid)
        if let heading = findElement(in: newElements, text: name, role: "AXHeading") {
            return "{\"success\": true, \"chat\": \"\(heading.description ?? heading.title ?? name)\"}"
        }
        // Even without heading verification, the click likely worked
        return "{\"success\": true, \"chat\": \"\(name)\", \"note\": \"clicked chat button, heading not verified\"}"
    }

    // Try static text as fallback
    if let textEl = findElement(in: elements, text: name) {
        clickElement(textEl)
        Thread.sleep(forTimeInterval: 0.8)
        return "{\"success\": true, \"chat\": \"\(name)\", \"note\": \"clicked text element\"}"
    }

    return "{\"success\": false, \"error\": \"Chat not found: \(name). Try scrolling or searching.\"}"
}

func handleReadMessages(args: [String: Value]?) throws -> String {
    let pid = try ensureWhatsAppRunning()
    let limit = (try getOptionalInt(from: args, key: "limit")) ?? 20

    let elements = traverseAXTree(pid: pid)

    // Messages in WhatsApp are AXGenericElement with descriptions like:
    // "message, Hello there!, 10:30 AM, Received from John"
    // "Your message, Hi!, 10:31 AM, Sent to John"
    // Also check AXStaticText for message content
    var messages: [MessageInfo] = []

    let genericElements = findElements(in: elements, role: "AXGenericElement")
    for el in genericElements {
        let desc = el.description ?? ""
        if desc.isEmpty { continue }

        // Parse "message, <text>, <time>, Received from <name>"
        if desc.hasPrefix("message, ") || desc.hasPrefix("Your message, ") {
            let isFromMe = desc.hasPrefix("Your message, ")
            let prefix = isFromMe ? "Your message, " : "message, "
            let rest = String(desc.dropFirst(prefix.count))

            // Split by ", " — but message text may contain commas
            // The pattern ends with ", <time>, Received from <name>" or ", <time>, Sent to <name>"
            var sender = ""
            var time = ""
            var text = rest

            // Try to extract "Received from X" or "Sent to X" from the end
            if let receivedRange = rest.range(of: #",\s+Received from (.+)$"#, options: .regularExpression) {
                let receivedPart = String(rest[receivedRange])
                sender = receivedPart.replacingOccurrences(of: #"^,\s+Received from "#, with: "", options: .regularExpression)
                text = String(rest[rest.startIndex..<receivedRange.lowerBound])
            } else if let sentRange = rest.range(of: #",\s+Sent to (.+)$"#, options: .regularExpression) {
                let sentPart = String(rest[sentRange])
                sender = sentPart.replacingOccurrences(of: #"^,\s+Sent to "#, with: "", options: .regularExpression)
                text = String(rest[rest.startIndex..<sentRange.lowerBound])
            }

            // Try to extract time from the remaining text (last ", HH:MM AM/PM" or similar)
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

    // Take only the last N messages
    let limitedMessages = Array(messages.suffix(limit))
    return serializeToJsonString(limitedMessages) ?? "[]"
}

func handleSendMessage(args: [String: Value]?) throws -> String {
    let name = try getRequiredString(from: args, key: "name")
    let message = try getRequiredString(from: args, key: "message")
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.5)

    // Step 1: Open the chat
    let elements = traverseAXTree(pid: pid)

    // Check if we're already in the right chat by looking at the heading
    var needToOpen = true
    if let heading = findElement(in: elements, text: name, role: "AXHeading") {
        fputs("log: already in chat with \(heading.description ?? name)\n", stderr)
        needToOpen = false
    }

    if needToOpen {
        if let chatBtn = findElement(in: elements, text: name, role: "AXButton") {
            clickElement(chatBtn)
            Thread.sleep(forTimeInterval: 0.8)
        } else {
            // Try search
            fputs("log: chat not found in sidebar, trying search\n", stderr)
            if let searchBtn = findElement(in: elements, text: "Search", role: "AXButton") {
                clickElement(searchBtn)
                Thread.sleep(forTimeInterval: 0.5)
            }
            // Look for search text field
            let searchElements = traverseAXTree(pid: pid)
            if let searchField = findElement(in: searchElements, text: "Search", role: "AXTextField") ??
               findElements(in: searchElements, role: "AXTextField").first {
                clickElement(searchField)
                Thread.sleep(forTimeInterval: 0.3)
                _ = pasteText(name)
                Thread.sleep(forTimeInterval: 1.0)

                let results = traverseAXTree(pid: pid)
                if let result = findElement(in: results, text: name, role: "AXButton") ??
                   findElement(in: results, text: name) {
                    clickElement(result)
                    Thread.sleep(forTimeInterval: 0.8)
                } else {
                    return "{\"success\": false, \"error\": \"Contact not found: \(name)\"}"
                }
            } else {
                return "{\"success\": false, \"error\": \"Could not find search field or chat: \(name)\"}"
            }
        }
    }

    // Step 2: Find compose field and type message
    let chatElements = traverseAXTree(pid: pid)

    // Verify we're in the right chat
    if let heading = findElement(in: chatElements, text: name, role: "AXHeading") {
        fputs("log: verified chat heading: \(heading.description ?? heading.title ?? "?")\n", stderr)
    }

    // Find the compose text area
    let textAreas = findElements(in: chatElements, role: "AXTextArea")
    let composeField = textAreas.first(where: {
        ($0.description ?? "").lowercased().contains("compose") ||
        ($0.description ?? "").lowercased().contains("message") ||
        ($0.description ?? "").lowercased().contains("type")
    }) ?? textAreas.last

    guard let compose = composeField else {
        return "{\"success\": false, \"error\": \"Could not find compose message field\"}"
    }

    // Click compose field
    clickElement(compose)
    Thread.sleep(forTimeInterval: 0.3)

    // Type message via paste
    guard pasteText(message) else {
        return "{\"success\": false, \"error\": \"Failed to paste message text\"}"
    }
    Thread.sleep(forTimeInterval: 0.3)

    // Press Return to send
    pressReturn()
    Thread.sleep(forTimeInterval: 0.5)

    return "{\"success\": true, \"to\": \"\(name)\", \"message\": \"\(message.prefix(100))\"}"
}

func handleSearch(args: [String: Value]?) throws -> String {
    let query = try getRequiredString(from: args, key: "query")
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.5)

    let elements = traverseAXTree(pid: pid)

    // Click search button or field
    if let searchBtn = findElement(in: elements, text: "Search", role: "AXButton") {
        clickElement(searchBtn)
        Thread.sleep(forTimeInterval: 0.5)
    }

    // Find and click search text field
    let afterClickElements = traverseAXTree(pid: pid)
    let textFields = findElements(in: afterClickElements, role: "AXTextField")
    let searchField = textFields.first(where: {
        ($0.description ?? "").lowercased().contains("search")
    }) ?? textFields.first

    guard let field = searchField else {
        return "{\"error\": \"Could not find search field\"}"
    }

    clickElement(field)
    Thread.sleep(forTimeInterval: 0.3)

    // Clear and type query
    sendKeyEvent(keyCode: 0, flags: .maskCommand) // Cmd+A
    Thread.sleep(forTimeInterval: 0.1)
    _ = pasteText(query)
    Thread.sleep(forTimeInterval: 1.5) // Wait for results

    // Read results
    let resultElements = traverseAXTree(pid: pid)
    var results: [[String: String]] = []

    let buttons = findElements(in: resultElements, role: "AXButton")
    for btn in buttons {
        let desc = btn.description ?? ""
        let val = btn.value ?? ""
        if desc.isEmpty { continue }
        let descLower = desc.lowercased()
        // Skip nav buttons
        if ["chats", "calls", "updates", "settings", "search", "back", "close", "all", "unread", "favorites", "groups"].contains(descLower) { continue }
        results.append(["name": desc, "preview": val])
    }

    // Close search with Escape
    pressEscape()

    return serializeToJsonString(results) ?? "[]"
}

func handleNavigate(args: [String: Value]?) throws -> String {
    let tab = try getRequiredString(from: args, key: "tab")
    let pid = try ensureWhatsAppRunning()
    activateWhatsApp(pid: pid)
    Thread.sleep(forTimeInterval: 0.3)

    let elements = traverseAXTree(pid: pid)

    // Map tab names
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

    // --- Tool Definitions ---

    let statusTool = Tool(
        name: "whatsapp_status",
        description: "Check if WhatsApp is running and accessibility is granted. Returns JSON with whatsappRunning, pid, accessibilityTrusted.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
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

    let openChatTool = Tool(
        name: "whatsapp_open_chat",
        description: "Open a chat by clicking it in the WhatsApp sidebar. Returns success/failure.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"), "description": .string("Contact or group name to open")])
            ]),
            "required": .array([.string("name")])
        ])
    )

    let readMessagesTool = Tool(
        name: "whatsapp_read_messages",
        description: "Read messages from the currently open WhatsApp chat. Returns array of messages with sender, text, time, and direction.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object(["type": .string("integer"), "description": .string("Max messages to return (default 20)")])
            ])
        ])
    )

    let sendMessageTool = Tool(
        name: "whatsapp_send_message",
        description: "Send a message to a WhatsApp contact. Opens the chat, types the message, and presses Return to send.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"), "description": .string("Recipient contact or group name")]),
                "message": .object(["type": .string("string"), "description": .string("Message text to send")])
            ]),
            "required": .array([.string("name"), .string("message")])
        ])
    )

    let searchTool = Tool(
        name: "whatsapp_search",
        description: "Search WhatsApp chats and messages by query text.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "description": .string("Search query text")])
            ]),
            "required": .array([.string("query")])
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

    let allTools = [statusTool, listChatsTool, openChatTool, readMessagesTool, sendMessageTool, searchTool, navigateTool]
    fputs("log: setupAndStartServer: defined \(allTools.count) tools\n", stderr)

    let server = Server(
        name: "WhatsAppMCP",
        version: "1.0.0",
        instructions: """
        WhatsApp MCP server for macOS. Controls the native WhatsApp Catalyst app via accessibility APIs.
        Tools: whatsapp_status, whatsapp_list_chats, whatsapp_open_chat, whatsapp_read_messages, whatsapp_send_message, whatsapp_search, whatsapp_navigate.
        WhatsApp must be installed and accessibility permissions must be granted.
        """,
        capabilities: .init(
            tools: .init(listChanged: true)
        )
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
            case "whatsapp_list_chats":
                result = try handleListChats(args: params.arguments)
            case "whatsapp_open_chat":
                result = try handleOpenChat(args: params.arguments)
            case "whatsapp_read_messages":
                result = try handleReadMessages(args: params.arguments)
            case "whatsapp_send_message":
                result = try handleSendMessage(args: params.arguments)
            case "whatsapp_search":
                result = try handleSearch(args: params.arguments)
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
