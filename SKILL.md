---
name: whatsapp-macos
description: "Control WhatsApp desktop (macOS Catalyst app) via native MCP tools. Send messages, read chats, search conversations, navigate settings. Use when: 'WhatsApp message', 'send WhatsApp', 'check WhatsApp', 'text someone on WhatsApp', 'read WhatsApp messages', 'WhatsApp unread', 'open WhatsApp'."
allowed-tools: mcp__whatsapp__whatsapp_status, mcp__whatsapp__whatsapp_list_chats, mcp__whatsapp__whatsapp_open_chat, mcp__whatsapp__whatsapp_read_messages, mcp__whatsapp__whatsapp_send_message, mcp__whatsapp__whatsapp_search, mcp__whatsapp__whatsapp_navigate
---

# WhatsApp macOS MCP Skill

Control the native WhatsApp Catalyst app via dedicated MCP tools. No manual PID management or accessibility tree parsing needed.

## Available Tools

| Tool | Description | Key params |
|------|-------------|-----------|
| `whatsapp_status` | Check if WhatsApp is running, accessibility granted | (none) |
| `whatsapp_list_chats` | List visible chats with names, last message, unread count | `filter`: "all"/"unread"/"favorites"/"groups" |
| `whatsapp_open_chat` | Open a chat by clicking it in sidebar | `name`: contact/group name |
| `whatsapp_read_messages` | Read messages from current open chat | `limit`: max messages (default 20) |
| `whatsapp_send_message` | Send message to a contact (opens chat + types + sends) | `name`: recipient, `message`: text |
| `whatsapp_search` | Search chats/messages | `query`: search text |
| `whatsapp_navigate` | Switch tabs | `tab`: "chats"/"calls"/"updates"/"settings"/"archived"/"starred" |

## Workflows

### Check Status
Call `whatsapp_status` — returns `whatsappRunning`, `pid`, `accessibilityTrusted`.

### List Chats
Call `whatsapp_list_chats` with optional `filter`. Returns JSON array of `{name, lastMessage, unreadCount}`.

### Read Messages
1. `whatsapp_open_chat` with the contact name
2. `whatsapp_read_messages` with optional `limit`
Returns `{sender, text, time, isFromMe}` array.

### Send Message
Call `whatsapp_send_message` with `name` and `message`. The tool handles: finding the chat, opening it, clicking compose, pasting text, pressing Return.

### Search
Call `whatsapp_search` with `query`. Returns matching chat names and previews.

### Navigate
Call `whatsapp_navigate` with `tab` name.

## Safety

- **Always confirm with user** before sending messages unless they gave explicit instructions
- The send tool verifies the chat heading matches the intended recipient
- If a contact isn't found, the tool tries search as fallback

## Setup

The MCP server must be registered in `~/.claude/settings.json`:
```json
"whatsapp": {
  "command": "/Users/matthewdi/whatsapp-mcp-skill-macos/bin/whatsapp-mcp"
}
```

Requires: WhatsApp desktop installed, accessibility permissions granted.
