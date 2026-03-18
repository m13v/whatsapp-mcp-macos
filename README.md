# WhatsApp MCP for macOS

An MCP (Model Context Protocol) server that lets AI assistants control the native WhatsApp macOS app via accessibility APIs.

## Features

- **Search contacts & chats** with structured results (name, preview, time, section)
- **Open chats** by clicking search results with index-based selection
- **Send messages** with post-send verification
- **Read messages** with parsed sender, text, timestamps
- **Get active chat** info including subtitle and recent messages
- **Start/quit** WhatsApp programmatically
- **Navigate** between tabs (chats, calls, updates, settings)
- **Scroll** through search results

## Requirements

- macOS 13+
- WhatsApp desktop app installed
- Accessibility permissions granted (System Settings > Privacy & Security > Accessibility)
- Swift 5.9+ / Xcode

## Installation

### Via npm (recommended)

```bash
npm install -g whatsapp-mcp-macos
```

### From source

```bash
git clone https://github.com/m13v/whatsapp-mcp-macos.git
cd whatsapp-mcp-macos
swift build -c release
```

## Configuration

Add to your Claude Code config (`~/.claude.json` under `mcpServers`):

### If installed via npm

```json
"whatsapp": {
  "type": "stdio",
  "command": "whatsapp-mcp",
  "args": [],
  "env": {}
}
```

### If built from source

```json
"whatsapp": {
  "type": "stdio",
  "command": "/path/to/whatsapp-mcp-macos/.build/release/whatsapp-mcp",
  "args": [],
  "env": {}
}
```

Then restart Claude Code or run `/mcp` to reconnect.

## Tools

| Tool | Description |
|------|-------------|
| `whatsapp_status` | Check if WhatsApp is running and accessibility is granted |
| `whatsapp_start` | Launch WhatsApp if not running |
| `whatsapp_quit` | Quit WhatsApp (graceful + force fallback) |
| `whatsapp_search` | Search contacts/chats, returns indexed structured results |
| `whatsapp_open_chat` | Click the Nth search result to open a chat |
| `whatsapp_get_active_chat` | Get current chat name, subtitle, and recent messages |
| `whatsapp_send_message` | Send message in current chat with delivery verification |
| `whatsapp_read_messages` | Read messages from current chat |
| `whatsapp_scroll_search` | Scroll search results to load more |
| `whatsapp_list_chats` | List sidebar chats with unread counts |
| `whatsapp_navigate` | Switch tabs (chats, calls, updates, settings) |

## Workflow

The recommended workflow for sending a message:

```
1. whatsapp_search("contact name")     → returns indexed results
2. whatsapp_open_chat(index: 0)        → clicks result, returns active chat name
3. whatsapp_get_active_chat()           → verify correct chat + see recent messages
4. whatsapp_send_message("hello!")      → sends with delivery verification
```

## How It Works

This MCP server uses macOS accessibility APIs (`AXUIElement`) to interact with the WhatsApp Catalyst app. It:

- Traverses the accessibility tree to find UI elements
- Clicks buttons by coordinates (with cursor position restoration)
- Pastes text via clipboard (Cmd+V) for reliable input
- Parses message descriptions from accessibility attributes
- Detects section headers (Chats/Contacts) to categorize search results

## License

MIT
