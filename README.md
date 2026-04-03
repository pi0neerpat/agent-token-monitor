# Claude Token Meter

A native macOS menu bar app that reads Claude credentials from Keychain, fetches current usage from Anthropic, and renders a compact current-session meter in the status bar. The app has visible UI in the menu bar and menu, but it does not open a traditional window.

## What It Does

1. Looks up a Claude OAuth token from supported Keychain storage
2. Calls `GET https://api.anthropic.com/api/oauth/usage`
3. Shows current-session remaining percentage and reset time in the macOS menu bar
4. Uses the bundled `clawd.png` icon and changes that icon from orange to yellow to red as remaining usage gets low
5. Provides a small menu with refresh, weekly values, extra usage, and quit

## Runtime Notes

- macOS 13.0+
- A supported Claude OAuth credential available in Keychain
- Network access to `https://api.anthropic.com`

This build is hardened for App Sandbox preparation:

- It no longer reads `~/.claude/.credentials.json`
- It no longer shells out to `/usr/bin/security`
- It only sends authenticated usage requests to the allowlisted Anthropic production host
- Logs are written under the app's Application Support directory rather than `~/Library/Logs`
- App bundle icons are generated from `app-icon.png`; the menu bar glyph remains `clawd.png`

## Build

```bash
./build.sh
```

This compiles the app and installs it to `~/Applications/Claude Token Meter.app`.

It is still a local development build path. App Store packaging and signing are intentionally not implemented in this repository yet.

## Launch

Open `~/Applications/Claude Token Meter.app` from Finder, or:

```bash
open ~/Applications/Claude\ Token\ Meter.app
```
