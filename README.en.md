# NotchHub

[中文](README.md)

A native macOS notch island for AI coding tools: quotas, agent status, tool approvals and keep-awake controls. SwiftUI/AppKit with no third-party Swift dependencies. The UI is currently Chinese only.

> Not affiliated with OpenAI, Anthropic, Google, Tencent, DeepSeek, Moonshot AI or Zhipu AI. All names belong to their owners.

## Features
- **Quotas**: DeepSeek / Kimi / GLM balances, Codex / Claude subscription limits, WorkBuddy credits, with low-balance alerts.
- **Agents**: status and 24-hour token usage for Claude Code, Codex, DSH and WorkBuddy.
- **Approvals**: approve or reject agent tool requests from the notch.
- **Keep awake**: on AC power, screen on, timed, and lid-closed.
- **Tools**: launcher for apps and shell commands; Clash Verge proxy status.

## Known limitations
WorkBuddy credits are unavailable when its login state is encrypted.

## Install
Requires macOS 14+, Apple Silicon and the Xcode Command Line Tools.

```bash
git clone https://github.com/w951083705-arch/NotchHub && cd NotchHub
./build.sh --install
```

Add API keys with the **API Key** button on the quota tab. They are stored only in your login keychain.

## Connect approvals
```bash
tools/approval-hooks.py status
tools/approval-hooks.py install      # or: install claude codex
tools/approval-hooks.py uninstall    # configs are backed up before every change
```

Claude Code, Codex and WorkBuddy use `PermissionRequest` hooks. Codex also asks you to trust the hook (`/hooks`, or Settings > Hooks in the app). Gemini (`agy`) only offers `PreToolUse`, so every shell command shows a card. DSH uses a plugin. Muse has no external approval interface.

If NotchHub is not running, times out (2 minutes) or fails, the agent falls back to its own approval. It never allows by default.

## Lid-closed mode
Regular power assertions cannot prevent lid-close sleep, so this mode sets the system `SleepDisabled` flag. You enter an admin password once, and a small root watchdog holds the setting. It pauses on battery (unless a timer is running) or at 15% and below when not charging, sleeps immediately if the lid is already closed, and restores the setting when you turn it off, quit, crash or shut down.

## Privacy
NotchHub has no server and uploads nothing. See [SECURITY.md](SECURITY.md) and the data table in the [Chinese README](README.md).
