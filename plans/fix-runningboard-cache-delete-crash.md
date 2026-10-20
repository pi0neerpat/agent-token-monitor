# Root cause: RunningBoard is killing the app, not a code crash

## Evidence

`log show --predicate "processID == <pid>"` around each disappearance shows, every time:

```
runningboardd: [app<application.com.scribular.agent-token-monitor...>:PID]
Terminating with context: <RBSTerminateContext| code:0xBADDD15C
explanation:CacheDeleteAppContainerCaches
requesting termination assertion for com.scribular.agent-token-monitor
reportType:None maxTerminationResistance:NonInteractive ...>
```

Observed 6 times in under an hour, every single time targeting this app and no other:
`13:07:31, 13:12:38, 13:18:07, 13:33:48, 13:39:05, 13:55:00`.

No `.ips` crash report is ever generated (confirms it's an external kill, not a
Swift trap/exception/segfault). `NSSetUncaughtExceptionHandler` never fires because
there's nothing to catch — the process is terminated directly by `runningboardd`.

## Why this app specifically

- `CacheDeleteAppContainerCaches` is macOS's storage-pressure reclaim path for
  **App Sandbox containers** (`~/Library/Containers/<bundle-id>/`). Disk free space
  on this machine is ~7.6GiB of 111GiB (~6.8% free) — low enough to trigger
  aggressive storage management sweeps.
- The app opts into App Sandbox (`entitlements.plist`: `com.apple.security.app-sandbox
  = true`), so it has a container that's eligible for this treatment. Non-sandboxed
  apps have no container and are not a target of this mechanism at all.
- The app runs as `.accessory` (menu-bar only, `NSApplicationActivationPolicyAccessory`),
  so it is always `NotVisible` to the window server. RunningBoard grants it
  `maxTerminationResistance: NonInteractive` — the lowest protection tier, with **no**
  opportunity to refuse or even be notified before termination. A normal foreground
  app would get stronger resistance.
- There is no LaunchAgent, login item, or `SMAppService` registration for this app,
  so nothing relaunches it after RunningBoard kills it — each kill is a real, visible
  crash requiring the user to manually reopen it. This matches "crashes every few
  minutes" exactly (the primary refresh timer is a 300s/5-minute `Timer`, and observed
  kill gaps cluster around 5–16 minutes).

## Why the earlier notarization/staple fix didn't help

That was a real gap (the `.app` wasn't carrying a stapled ticket, so offline Gatekeeper
checks could fail) and is still worth keeping, but it's unrelated to this failure mode.
`runningboardd`'s termination here has nothing to do with code signing or Gatekeeper —
it's the sandbox-container cache reclaim path.

## Recommended fix

**Drop the App Sandbox entitlement.** This app is distributed via Developer ID +
notarization (`release.sh`), not the Mac App Store, so sandboxing is optional here,
and it's the actual `com.apple.security.app-sandbox` entitlement that makes the app
eligible for `CacheDeleteAppContainerCaches` in the first place.

This also fixes a separate bug found during this investigation: the sandboxed app
spawns `codex` as a child process (`ProviderClients.swift`/`CodexRPC.swift`), which
inherits the sandbox, causing the child's `$HOME`-relative paths (`~/.codex/...`) to
redirect into `~/Library/Containers/com.scribular.agent-token-monitor/Data/.codex/`
instead of the user's real `~/.codex/`. Without sandboxing, the subprocess resolves
paths normally.

Steps:
1. Remove `com.apple.security.app-sandbox` (and the now-unnecessary
   `com.apple.security.files.user-selected.read-only`) from `entitlements.plist`.
   Keep `com.apple.security.network.client` if hardened runtime still requires
   explicit network entitlement (it does not strictly need sandbox to be on).
2. Rebuild via `release.sh`, re-sign, re-notarize, re-staple the `.app` (staple-before-DMG
   fix from the uncommitted `release.sh` diff should be kept regardless).
3. Confirm `~/Library/Containers/com.scribular.agent-token-monitor/` is no longer created
   on next launch, and `~/.codex/` is read directly.
4. Optionally: add a lightweight `SMAppService.agent` (macOS 13+) registration with
   `KeepAlive`-style auto-restart as defense in depth, in case RunningBoard/jetsam
   ever terminates the app for unrelated reasons (e.g. real memory pressure) in the
   future — this makes any future unexpected termination self-healing instead of a
   user-visible crash.

## Not yet decided / needs user input

- Whether to also implement the auto-restart watchdog (step 4) now or treat it as a
  separate follow-up.
- Disposition of the still-uncommitted `MeterUI.swift` diff (`layoutSubtreeIfNeeded()`
  removal) — unrelated to this root cause, unclear if it was an earlier abandoned
  attempt at fixing this same symptom.

## Re-confirmed 2026-10-19

- Fix was never applied: `entitlements.plist` still has `com.apple.security.app-sandbox = true`.
- Free disk space dropped further: 4.7GiB of 111GiB (~4%) on `/System/Volumes/Data`.
- Same kill signature today at `19:39:17` and `20:20:36` (code `0xBADDD15C`,
  `CacheDeleteAppContainerCaches`, `maxTerminationResistance:NonInteractive`).
- Full trigger chain captured for the 20:20:36 kill:
  `dasd` scores `com.apple.cache_delete.CriticalPurge` (0.99 vs threshold 0.08) at
  20:20:30 → `deleted` runs CriticalPurge → `runningboardd` terminates the app ~6s later.
- The container holds only 1.6MB with an empty `Caches/`, so the app doesn't cause
  the pressure; it's killed just because it has a container and is non-interactive.
- Note: in zsh, plain `log` is a shell builtin. Use `/usr/bin/log show ...` or you get empty results.

## Applied 2026-10-19

- `entitlements.plist`: removed `app-sandbox` and `files.user-selected.read-only`; kept `network.client`.
- `CodexAuthAccess.canReadCredentials()`: Codex is enabled when the bookmark exists OR the
  default `auth.json` is readable. Without the sandbox, UserDefaults moves out of the container,
  so upgrading users would otherwise lose their bookmark and Codex would be hidden.
- Removed "sandboxed" wording from the Enable Codex alert and the read-error message.
- `./build.sh` succeeded; `codesign -d --entitlements -` shows only `network.client`. `swift test`: 14/14 pass.
- Pending: launch + 30-min soak test with `/usr/bin/log stream` watching for `0xBADDD15C`;
  `./release.sh release` (needs Apple credentials); auto-restart watchdog still deferred.
- `release.sh sandbox` mode removed along with the Mac App Store path (MAS requires App Sandbox, which reintroduces this kill).
