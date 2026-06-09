# NOOP

NOOP is a local-first iPhone app for a WHOOP 4.0 strap. It connects directly to
the strap over Bluetooth, stores the data on the phone, and builds a WHOOP-style
dashboard around live heart rate, sleep, recovery, strain, workouts, steps, and a
haptic wake alarm.

The app is meant for direct Xcode installs while it is being developed. It is not
on the App Store and does not require a WHOOP cloud account.

> NOOP is an independent project. It is not affiliated with, endorsed by, or
> connected to WHOOP, Inc. It is also not a medical device. Recovery, strain,
> sleep stages, SpO2-derived values, skin-temperature values, and illness hints
> are research-grounded estimates from consumer hardware, not clinical results.

## What NOOP Does

- Connects to a WHOOP 4.0 over Bluetooth.
- Streams live heart rate and R-R interval data.
- Offloads historical WHOOP sensor data into a local SQLite store.
- Displays a full-screen iPhone dashboard with Today, Workouts, Status, and More.
- Calculates recovery locally from WHOOP sleep, HRV, resting HR, respiratory
  rate, recent load, and optional raw SpO2 / skin-temperature signals.
- Calculates strain from awake heart-rate load using TRIMP-style training load.
- Shows recovery-adjusted load as a separate interpretation of strain.
- Detects and plots sleep from WHOOP HR, R-R, respiration, and motion data.
- Records workouts with HR graphs, strain, notes, and workout-specific fields.
- Records run and hike routes only while those workouts are active.
- Supports workout plans for strength training and swimming.
- Shows steps from WHOOP-derived step data when available, otherwise estimated
  from WHOOP motion.
- Sends haptic buzz commands and can arm the strap alarm.

## Main Screens

### Today

The Today tab is the main dashboard.

- Recovery ring
- Strain ring
- Recovery-adjusted load inside the strain card
- Sleep duration
- Steps
- Calories when available
- 12-hour heart-rate preview
- Full-day heart-rate detail on tap
- Logged and detected workouts
- Calendar picker with recovery-colored days

Tapping Recovery or Strain opens a short explanation of how the app is computing
those values.

### Workouts

The Workouts tab supports both quick workouts and reusable plans.

Current workout types include:

- Strength training
- Swimming
- Treadmill
- Run
- Hiking
- Stair master

Strength plans can include exercises, sets, reps, and per-set weight logging.
When you repeat a plan, NOOP shows the previous weight below the current input.

Swim plans can include stroke, sets, and distance.

Runs and hikes use location only while the workout is active. Finished run/hike
workouts can show a simplified route map, distance, pace, heart-rate graph,
strain, and notes.

### Status

The Status tab is the live device page.

- Connection state
- Current heart rate
- Battery
- R-R intervals
- Live sensor status
- Disconnect and buzz controls

### Sleep

Sleep is derived locally from WHOOP data. NOOP detects the main overnight sleep
window, stages it approximately, and displays:

- Total sleep time
- Sleep stages
- Sleep-stage timeline
- Sleep HRV
- Resting HR
- Raw SpO2 ratio when available
- Skin-temperature ADC value when available

The app no longer depends on Apple Health to calculate recovery. Apple Health
read/export helper code may still exist in the repository, but the active app
flow is WHOOP/local-first.

## How Metrics Are Calculated

### Recovery

Recovery is a 0-100 local NOOP score. It is not WHOOP's proprietary score.

The current implementation uses:

- Overnight HRV, RMSSD, compared with your own baseline
- Overnight resting HR compared with your own baseline
- Sleep duration, efficiency, and restorative-stage estimate
- Respiratory-rate drift when available
- Recent training load
- Raw SpO2 red/IR ratio when available
- Raw skin-temperature ADC value when available

HRV and resting HR are the strongest signals. Missing optional signals do not
block recovery. If the app is still building a baseline, it can show a
provisional recovery score.

### Strain

Strain is a 0-21 cardiovascular load estimate from WHOOP heart-rate data.

The app:

- Removes detected sleep intervals first
- Uses awake heart-rate samples
- Estimates heart-rate reserve
- Converts time in HR zones into TRIMP-style load
- Maps that load onto a logarithmic 0-21 strain scale

Sleep is not counted toward daily strain.

### Recovery-Adjusted Load

Recovery-adjusted load is separate from raw strain.

Raw strain remains the measured training-load estimate. Adjusted load asks:

> How costly does today's raw strain look given today's recovery?

The app converts strain back into its underlying training load, adjusts it by a
recovery-capacity curve based on the red/yellow/green recovery bands, then maps
it back onto the 0-21 scale. Green recovery leaves load mostly unchanged. Yellow
and red recovery make the same raw strain show as a higher adjusted load.

### Sleep

Sleep detection uses WHOOP heart rate, R-R intervals, respiration, and motion.
The app tries to select the main overnight sleep block for the selected day so
evening stillness does not replace the real sleep session.

Sleep stages are approximate. They are useful for trends and visualization, but
they should not be treated as clinical sleep staging.

## Privacy

NOOP is designed to run locally.

- WHOOP data is stored on the phone in SQLite.
- The app does not require a WHOOP account.
- The app does not upload biometric data to a NOOP server.
- Apple Health is not required for the current recovery/strain/sleep flow.
- Location starts only for run and hike workouts and is used for route logging.

## iPhone Install

NOOP is currently installed directly from Xcode.

Requirements:

- macOS with Xcode installed
- An iPhone, tested during development with iPhone 15
- A WHOOP 4.0 strap
- A free or paid Apple Developer account signed into Xcode

Steps:

1. Open `Strand.xcodeproj` in Xcode.
2. Select the `NOOPiOS` scheme.
3. Plug in your iPhone and select it as the run destination.
4. In Signing & Capabilities, choose your development team.
5. Press Run.
6. On the iPhone, allow Bluetooth permissions.
7. Keep the official WHOOP app closed while pairing if the strap is not showing
   up in NOOP.

If Xcode says the app requires a development team, select your Apple ID team in
Signing & Capabilities for the `NOOPiOS` target.

## Project Layout

```text
StrandiOS/
  App/                 SwiftUI iPhone app screens and navigation
  BLE/                 WHOOP scan/connect/live BLE handling
  Collect/             Historical offload and local collection
  Data/                iOS metric snapshots, workout recorder, strain helper
  Health/              HealthKit helper code
  Resources/           Info.plist, assets, app icon

Packages/
  WhoopProtocol/       WHOOP frame parsing, commands, CRC, protocol types
  WhoopStore/          Local SQLite persistence via GRDB
  StrandAnalytics/     HRV, recovery, strain, sleep, workouts, readiness math
  StrandDesign/        Shared colors, charts, and SwiftUI components
  StrandImport/        Import helpers retained from earlier app work

android/               Older Android work area
```

## Current Development Notes

- WHOOP 4.0 is the active target.
- WHOOP 5.0 support is not the current focus.
- Background collection on iOS is limited by iOS Bluetooth/background execution
  rules. The most reliable collection happens while the app is active or while
  iOS allows the BLE session to continue.
- Sleep/recovery quality improves after multiple nights because the app needs
  personal baselines.
- Raw SpO2 and skin-temperature values are included as trend signals when
  available, but they are not medically calibrated.

## Research Grounding

The math is intentionally transparent and approximate.

- HRV: RMSSD-style overnight HRV and personal-baseline comparison
- Strain: heart-rate reserve, Edwards/Banister-style TRIMP load, logarithmic
  0-21 mapping
- Training load: acute/chronic workload concepts
- Sleep: actigraphy-inspired sleep/wake detection plus HR/R-R/respiration
  features for approximate staging
- Recovery: HRV-dominant readiness with resting HR, sleep, respiration, recent
  load, and illness-watch signals

These methods are useful for personal trends, not diagnosis.

## Disclaimer

NOOP is experimental software for personal data access and self-tracking. It may
be wrong, incomplete, or inconsistent with the official WHOOP app. Do not use it
for medical decisions, safety-critical decisions, or diagnosis. Use it only with
hardware you own and only where doing so is lawful and allowed.
