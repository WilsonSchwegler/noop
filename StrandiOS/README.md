# NOOP iOS Development Target

This is the iPhone development target for direct Xcode installs while the full
iOS app is being ported.

## What works now

- Launches as a native SwiftUI iPhone app.
- Uses the NOOP app icon artwork.
- Presents the currently backed iPhone features: Today, Live, Activity,
  Workouts, Sleep, Alarm, and Settings.
- Requests Bluetooth access.
- Scans for the WHOOP 4.0 custom BLE service.
- Connects to a discovered strap.
- Subscribes to the standard Heart Rate characteristic (`180D` / `2A37`).
- Reads/subscribes to the standard Battery characteristic (`180F` / `2A19`).
- Performs the same benign confirmed `GET_BATTERY_LEVEL` write used by the macOS
  app to trigger WHOOP 4.0 just-works bonding.
- Runs the WHOOP 4.0 connect handshake, sets/reads clock, and requests historical
  offload into the local SQLite store.
- Persists WHOOP HR, R-R, battery, and decoded historical sensor streams locally.
- Calculates strain, workout detection, HRV, resting HR, and recovery from the
  WHOOP store. Apple Health is used only for sleep analysis/sleep score.
- Can send a safe haptic buzz command and arm the strap alarm once the command
  channel is ready.

## What is not ported yet

- WHOOP 5.0 / MG custom protocol support.
- Widgets, App Intents, imports, and the full desktop dashboard UI.

## Run on an iPhone

1. Install full Xcode, not just Command Line Tools.
2. Run `xcodegen generate` from the repo root.
3. Open `Strand.xcodeproj`.
4. Select the `NOOPiOS` scheme.
5. Select your connected iPhone as the run destination.
6. In Signing & Capabilities, choose your Apple ID team.
7. Press Run.
8. On the iPhone, allow Bluetooth when prompted.

For first pairing, keep the official WHOOP app closed or out of range so the strap
is available to NOOP.
