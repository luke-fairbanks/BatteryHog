<div align="center">
  <h1>Battery Hog</h1>
  <p><b>A native macOS app that shows what's draining your battery — and actually helps you fix it.</b></p>
</div>

![Battery Hog overview](docs/overview.png)

Battery Hog is a small, fast, **100% local** menu-bar + window app for Apple Silicon Macs. It shows live battery, memory, and per-app energy use, keeps a real charge history, estimates *why* your battery drains fast, and lets you quit the worst offenders — all read straight from built-in macOS tools, with nothing sent anywhere.

No Electron, no dependencies: a tiny Swift/WebKit shell around a Python standard-library backend and an HTML/CSS dashboard.

## Download

**[⬇︎ Download the latest .dmg →](https://github.com/luke-fairbanks/BatteryHog/releases/latest)** — open it and drag **Battery Hog** to Applications. Builds are signed and notarized, so it opens like any other app. (Prefer to build it yourself? See [Install](#install).)

Or with Homebrew:

```bash
brew install --cask luke-fairbanks/tap/battery-hog
```

Requires macOS 11+ on Apple Silicon.

## Features

- **Overview** — battery ring (state-colored), **live power draw in watts**, memory-pressure gauge, top energy users with real app icons, and a Low Power Mode toggle.
- **Processes** — sortable list (Impact / CPU / Memory) of apps grouped by process, with a Quit button. System processes are protected; the header stays pinned while rows scroll.
- **Workloads** — groups short-lived Node, Rust, Gradle/Kotlin, CocoaPods, test, scan, and compiler processes by project, including the coding agent that launched them.
- **Battery** — a **charge-history chart** (Last 24 Hours / Last 10 Days, built from the system power log) plus maximum capacity, condition, cycle count, and temperature.
- **Insights** — answers *"why does my battery drain so fast?"*: typical drain rate (%/hr), projected runtime per charge, time on battery, charge sessions, and overnight wake-ups.
- **Sleep blockers** — identifies apps holding long-running idle-sleep assertions and flags overly long battery display timeouts.
- **Battery-aware Agent Mode** — an opt-in command gate that queues heavyweight agent builds on battery, caps supported compiler workers, and automatically becomes unrestricted on AC power.
- **Smart suggestions** — contextual, actionable tips (coordinate concurrent builds, release stuck sleep assertions, restart after long uptime, free RAM under pressure, plug in when low, …). Mute tips for apps you can't quit.
- **Opt-in alerts** — native notifications for low battery, full charge, runaway-CPU apps, and sustained macOS thermal pressure with likely workload attribution.
- **Configurable menu bar** — choose what the status item shows: battery %, watts, time remaining, and/or the top app.

<p align="center"><img src="docs/battery.png" width="760" alt="Charge history"></p>

<p align="center"><img src="docs/processes.png" width="760" alt="Processes ranked by energy impact"></p>

## Battery-aware Agent Mode

Battery Hog remains advisory by default. When Agent Mode is enabled on the **Workloads**
page, coding agents can opt into coordination by prefixing a heavyweight command with
the gate command shown in the app:

```bash
python3 "/Applications/Battery Hog.app/Contents/Resources/batteryhog_gate.py" -- cargo check
```

On battery, the gate shares a configurable number of heavy-job lanes across agents and
applies conservative worker limits to supported toolchains. On AC power it immediately
passes commands through unchanged. It never kills, pauses, or silently intercepts an
ungated process; agents keep researching and editing in parallel while builds queue.

## Install

Requires macOS on Apple Silicon and the Xcode command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/luke-fairbanks/BatteryHog.git
cd BatteryHog
bash src/build.sh        # builds "Battery Hog.app" and installs it to /Applications
```

Then launch **Battery Hog** from Spotlight or Launchpad.

### Optional: password-free Low Power Mode

Toggling Low Power Mode and reading detailed energy normally prompt for your admin
password. To skip that, run the included helper once — it installs a **tightly-scoped**
`sudoers` rule that lets *only* two exact commands run without a password (and nothing else):

```bash
sudo bash src/enable-no-password.sh      # undo: sudo rm /etc/sudoers.d/battery-hog
```

Everything else in the app works without it.

## Building a signed, notarized release

`src/build.sh` makes an **unsigned** local build (fine for yourself, but Gatekeeper warns
on first launch). To produce a notarized `.dmg` that opens with no warning, you need an
Apple Developer Program membership and a *Developer ID Application* certificate, then:

```bash
# one-time: save notarization credentials
xcrun notarytool store-credentials BatteryHog-notary \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"

# build → sign (hardened runtime) → notarize → staple → package
SIGN_ID="Developer ID Application: Your Name (TEAMID)" bash src/release.sh
```

This outputs `dist/BatteryHog-<version>.dmg`, stapled and ready to share. Attach it to a
GitHub Release:

```bash
gh release create v1.3.1 dist/BatteryHog-1.3.1.dmg --title "Battery Hog 1.3.1"
```

> The app uses no third-party libraries, so it needs no special hardened-runtime
> entitlements — `src/release.sh` signs it with `--options runtime` and nothing else.

## How it works

The backend reads only built-in macOS tools and exposes them on `127.0.0.1`:

| Data | Source |
|---|---|
| Battery %, state, time | `pmset` |
| Live watts, health, cycles, temp | `ioreg` (AppleSmartBattery), `system_profiler` |
| Charge history + wake events | `pmset -g log` |
| Memory pressure / swap | `vm_stat`, `sysctl` |
| Per-app CPU / memory | `ps` |
| Project workloads | `ps`, process ancestry, and cached `lsof` working directories |
| Sleep blockers | `pmset -g assertions`, `pmset -g custom` |
| Agent Mode queue | Local JSON registry under Application Support |
| Uptime | `sysctl kern.boottime` |

The Swift shell (`src/BatteryHogApp.swift`) hosts the dashboard in a `WKWebView` with a
translucent sidebar, serves real app icons, and runs the menu-bar item.

## Privacy

100% local. Battery Hog reads only from the macOS tools above and shows the results in its
own window. **Nothing is sent anywhere** — no network requests, no analytics. The admin
password (if you use Low Power Mode) goes straight to macOS's own prompt.

## License

[MIT](LICENSE) © Luke Fairbanks
