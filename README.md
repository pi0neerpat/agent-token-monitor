<h1 align="center">Agent Token Monitor</h1>

<p align="center">
  <a href="./LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT">
  </a>
  <br/>
Monitor your Claude and Codex subs with a lightweight macOS taskbar item.
</p>

<p align="center">
<img src="./screenshot-4.png" alt="Agent Token Monitor in action" width="500">
</p>

## Install

**Option 1: Download from Releases**

Install the `.dmg` from [Releases](https://github.com/pi0neerpat/claude-token-meter/releases)

**Option 2: Build Locally**

```bash
./build.sh
```

You'll need to grant the app permission to access your Claude Oauth token. 

<img src="./permissions.png" alt="Agent Token Monitor permissions prompt" width="500">

And for Codex, we only need access to auth.json. Otherwise the app is sandboxed.

## Usage

Click the menu bar icon to see your usage. The icon color shows your status:
- **Orange** — comfortable
- **Yellow** — getting close
- **Red** — approaching limit

<img src="./screenshot-2.png" alt="Agent Token Monitor in action" width="500">

