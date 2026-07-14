<div align="center">
  <h1>Battery Hog</h1>
  <p><b>A native macOS app that shows what's draining your battery — and actually helps you fix it.</b></p>
</div>

![Battery Hog overview](docs/overview.png)

Battery Hog is a small, fast menu-bar + window app for Apple Silicon Macs. It shows live system-wide battery power and memory, ranks apps with a relative CPU-and-memory impact estimate, keeps a real charge history, estimates *why* your battery drains fast, and lets you quit likely contributors. The app estimate is a comparison aid, not a measurement of per-app watts. Monitoring stays **100% local** and is read straight from built-in macOS tools.

No Electron and no runtime dependencies: the monitor, menu-bar app, and optional Agent Mode helper are native Swift. The interface is a bundled HTML/CSS dashboard hosted by WebKit, with Sparkle included for signed, opt-in software updates.

## Download

**[⬇︎ Download the latest .dmg →](https://github.com/luke-fairbanks/BatteryHog/releases/latest)** — open it and drag **Battery Hog** to Applications. Builds are signed and notarized, so it opens like any other app. Direct-download installs can check for signed updates in the app; periodic checks are off until you opt in. (Prefer to build it yourself? See [Install](#install).)

Or with Homebrew:

```bash
brew install --cask luke-fairbanks/tap/battery-hog
```

Homebrew installs remain Homebrew-managed. Battery Hog detects the cask and shows the matching `brew upgrade` command instead of starting its built-in updater.

Version 1.4.0 is the updater bootstrap release. Anyone coming from 1.3.1 or earlier must install it manually once; later direct-download releases can update in place.

Requires macOS 11+ on Apple Silicon.

## Features

- **Overview** — battery ring (state-colored), **live system-wide power draw in watts**, memory-pressure gauge, top estimated app contributors with real app icons, and a Low Power Mode toggle.
- **Processes** — sortable list (Estimated Impact / CPU / Memory) of apps grouped by process, with a Quit button. Estimated Impact is a relative ranking based on current CPU and memory activity, not per-app watts. System processes are protected; the header stays pinned while rows scroll.
- **Workloads** — groups short-lived Node, Rust, Gradle/Kotlin, CocoaPods, test, scan, and compiler processes by project, including the coding agent that launched them.
- **Battery** — a **charge-history chart** (Last 24 Hours / Last 10 Days, built from the system power log) plus maximum capacity, condition, cycle count, and temperature.
- **Insights** — answers *"why does my battery drain so fast?"*: typical drain rate (%/hr), projected runtime per charge, time on battery, charge sessions, and overnight wake-ups.
- **Sleep blockers** — identifies apps holding long-running idle-sleep assertions and flags overly long battery display timeouts.
- **Battery-aware Agent Mode** — an opt-in command gate that queues heavyweight agent builds on battery, caps supported compiler workers, and automatically becomes unrestricted on AC power.
- **Smart suggestions** — contextual, actionable tips (coordinate concurrent builds, release stuck sleep assertions, restart after long uptime, free RAM under pressure, plug in when low, …). Mute tips for apps you can't quit.
- **Opt-in alerts** — native notifications for low battery, full charge, runaway-CPU apps, and sustained macOS thermal pressure with likely workload attribution.
- **Configurable menu bar** — choose what the status item shows: battery %, watts, time remaining, and/or the top app.
- **Signed software updates** — check manually or opt in to daily checks; Homebrew copies stay managed by Homebrew.

<p align="center"><img src="docs/battery.png" width="760" alt="Charge history"></p>

<p align="center"><img src="docs/processes.png" width="760" alt="Processes ranked by estimated impact"></p>

## Battery-aware Agent Mode

Battery Hog remains advisory by default. When Agent Mode is enabled on the **Workloads**
page, coding agents can opt into coordination by prefixing a heavyweight command with
the gate command shown in the app:

```bash
"/Applications/Battery Hog.app/Contents/Helpers/batteryhog-gate" -- cargo check
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

# VERSION is the single source for the app, DMG, tag and appcast version
VERSION="$(<VERSION)"

# build → sign nested Sparkle helpers + app → package → notarize → staple → appcast
SIGN_ID="Developer ID Application: Your Name (TEAMID)" bash src/release.sh
```

The build downloads the pinned Sparkle binary distribution into `.build/`, verifies its SHA-256, and embeds its license. A full release outputs both `dist/BatteryHog-$VERSION.dmg` and a signed `dist/appcast.xml`.

Sparkle's Ed25519 private key stays in the login Keychain under `com.lukefairbanks.batteryhog`; only its public key is committed. Set it up once on a new release Mac with `src/fetch_sparkle.sh` and Sparkle's `generate_keys` tool, then keep an encrypted offline backup of that key.

After the release has been reviewed on `main`, stage both assets together as a draft:

```bash
bash src/stage_release.sh
# Review the draft and both install paths before making it live.
gh release edit "v$VERSION" --repo luke-fairbanks/BatteryHog --draft=false --latest

# Once the GitHub release is public, derive the Homebrew version + SHA from it.
# This stages the tap diff but deliberately does not commit or push it.
bash src/stage_homebrew_cask.sh
```

The app is not sandboxed and needs no special hardened-runtime entitlements. `src/release.sh` signs Sparkle's nested helpers deepest-first, then the framework, Battery Hog, and the DMG before notarization. The appcast is generated only after the final DMG is stapled because its EdDSA signature covers those exact bytes.

## How it works

The in-process Swift monitor reads only built-in macOS tools. Its allow-listed native bridge is available only to the dashboard bundled inside the app; Battery Hog does not open a local server or listening port.

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

The Swift app hosts the dashboard in a `WKWebView` with a translucent sidebar, serves real app icons, runs the menu-bar item, and shares one native sampling engine between them. Agent Mode uses a separately signed native helper inside the app bundle.

## Privacy

Battery monitoring is 100% local. Battery Hog reads only from the macOS tools above and shows the results in its own window. There is no analytics, monitoring upload, or system profiling. The only outbound request is to GitHub's signed update feed when you manually check for an update or opt in to periodic checks; automatic checks are off by default. As with any web request, GitHub can see the request's IP address and app version. Homebrew-managed installs do not use the built-in updater. The admin password (if you use Low Power Mode) goes straight to macOS's own prompt.

Sparkle is included under its permissive license, bundled in the app as `Sparkle-LICENSE.txt`.

## License

[MIT](LICENSE) © Luke Fairbanks
