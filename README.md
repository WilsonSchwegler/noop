# WarbFit

WarbFit is a local-first fitness tracker app. It connects directly to a compatible
strap over Bluetooth, stores sensor data locally, and builds an iPhone dashboard
for heart rate, recovery, strain, sleep, workouts, steps, and a haptic wake alarm.

The project currently contains the active iOS app, the Android app target, shared
Swift packages used by iOS, and the assets those targets compile. The old desktop
Swift app target, legacy project files, deep-dive docs, helper CLIs, and
demo/sample-data builds have been removed so the repo stays focused on phone apps.

WarbFit is independent software for hardware you own. It is not a medical device.
Recovery, strain, sleep stages, SpO2-derived values, skin-temperature values, and
illness hints are research-grounded estimates from consumer hardware, not clinical
results.

## Features

- Direct Bluetooth connection to a compatible fitness tracker strap.
- Local heart-rate, R-R interval, battery, motion, sleep, and workout storage.
- Today dashboard with recovery, strain, recovery-adjusted load, sleep, steps,
  calories when available, and heart-rate charts.
- Workout recording for strength training, swimming, treadmill, run, hiking, and
  stair master.
- Strength and swim workout plans with repeatable set/weight logging.
- Run and hike route recording only while those workouts are active.
- Local sleep detection, approximate sleep staging, sleep HRV, resting HR, raw
  SpO2 ratio, and skin-temperature ADC display when available.
- Local recovery scoring from sleep, HRV, resting HR, respiration, recent load,
  and optional illness-watch signals.
- Awake-only strain calculation from heart-rate-load research methods.
- Haptic buzz and strap alarm controls.
- Local backup/export and import/restore flow.

## iPhone Install

WarbFit is currently installed directly from Xcode.

Requirements:

- macOS with Xcode installed
- iPhone running iOS 16 or newer
- Compatible fitness tracker strap
- Apple Developer account signed into Xcode

Steps:

1. Open `WarbFit.xcodeproj` in Xcode.
2. Select the `WarbFitiOS` scheme.
3. Plug in your iPhone and select it as the run destination.
4. In Signing & Capabilities, choose your development team.
5. Press Run.
6. On the iPhone, allow Bluetooth permissions.
7. Keep the official companion app closed while pairing if the strap is not
   showing up in WarbFit.

## Project Layout

```text
StrandiOS/
  App/                 SwiftUI iPhone app screens and navigation
  BLE/                 iOS Bluetooth scan/connect/live data handling
  Collect/             Historical offload and local collection
  Data/                iOS metric snapshots, workout recorder, strain helpers
  Health/              HealthKit helper code
  Resources/           Info.plist, entitlements, assets, app icon

Packages/
  TrackerProtocol/       Internal BLE frame parsing, commands, CRC, protocol types
  TrackerStore/          Local SQLite persistence via GRDB
  StrandAnalytics/     HRV, recovery, strain, sleep, workout, readiness math
  StrandDesign/        Shared SwiftUI colors, charts, and components

android/
  app/                 Android WarbFit application
```

The `TrackerProtocol` and `TrackerStore` package names are internal implementation
names retained to avoid a risky source/storage migration. They are part of the
active app build.

## Verification

Useful local checks:

```sh
xcodebuild -project WarbFit.xcodeproj -scheme WarbFitiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd android && ANDROID_HOME=/Users/wilsonschwegler/Library/Android/sdk GRADLE_USER_HOME=.gradle ./gradlew testDebugUnitTest
```

## Notes

- The app stores biometric data locally.
- The app does not require a cloud account.
- Location starts only for outdoor run and hike workouts.
- Background Bluetooth collection is still subject to iOS background execution
  behavior.
- Metrics improve as WarbFit builds a personal baseline over multiple nights.
