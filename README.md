# LiftLog

LiftLog is a local-first strength training log built with SwiftUI, SwiftData, Charts, HealthKit, and WatchConnectivity. The MVP supports an exercise library, Push/Pull/Legs routines, quick workouts, set-by-set logging, rest timers, workout history, calendar tracking, progress charts, HealthKit authorization, Health workout export, and a watchOS workout-control foundation.

## Project Structure

```text
训练/
├── 训练/
│   ├── __App.swift
│   ├── ContentView.swift
│   ├── Models.swift
│   ├── Utilities.swift
│   ├── Services.swift
│   ├── ViewModels.swift
│   ├── SeedData.swift
│   ├── WatchAppViews.swift
│   ├── LiftLog.entitlements
│   └── Assets.xcassets
├── LiftLogWatch/
│   ├── LiftLogWatchApp.swift
│   └── LiftLogWatch.entitlements
├── 训练Tests/
│   └── __Tests.swift
├── 训练UITests/
└── README.md
```

## Main Modules

- `Models.swift`: SwiftData models for `Exercise`, `WorkoutRoutine`, `RoutineExercise`, `WorkoutSession`, `WorkoutExercise`, `SetRecord`, `HeartRateSample`, `UserSettings`, and `BodyMeasurement`.
- `Utilities.swift`: volume calculation, Epley 1RM, weekly/monthly aggregation, muscle volume, heart-rate zones, unit conversion, and rest timer notifications.
- `Services.swift`: `HealthKitManager`, `WatchConnectivityManager`, and `ExportManager`.
- `ViewModels.swift`: MVVM layer for workout sessions, routines, exercise library, calendar, and progress analytics.
- `ContentView.swift`: iOS UI with tabs for Dashboard, Train, Calendar, Progress, Library, and Settings.
- `LiftLogWatch/LiftLogWatchApp.swift`: standalone watchOS app target with start, active metrics, set completion, pause/resume, end workout, `HKWorkoutSession`, `HKLiveWorkoutBuilder`, and `WatchConnectivity`.
- `WatchAppViews.swift`: shared/reference watchOS views kept behind `#if os(watchOS)` for future shared-target extraction.
- `SeedData.swift`: preset common strength exercises, Push/Pull/Legs templates, settings, and sample workout history.

## Permissions and Capabilities

The project includes HealthKit entitlements for the iOS app and `LiftLogWatch` target. Confirm your Apple developer team and capabilities in Xcode before testing on device:

- HealthKit for the iOS app target.
- HealthKit for the watchOS app target.
- WatchConnectivity by embedding a Watch App target and including shared model/service files in both targets.
- User Notifications are requested locally for rest timer completion alerts.

HealthKit permissions requested:

- Read: heart rate, active energy burned, workouts, body mass.
- Write: workouts, active energy burned.

The app does not fabricate heart rate or calorie data. Without authorization or Apple Watch data, workout summaries keep those fields empty.

## Apple Watch Target

This project now includes a `LiftLogWatch` watchOS target and scheme. It provides:

- Start quick workout or seeded routine names.
- Pause, resume, and end.
- Live heart rate, average heart rate, and active energy through `HKLiveWorkoutBuilder`.
- Current exercise/set display from iPhone sync state.
- Complete-current-set command back to iPhone over `WatchConnectivity`.

Simulator limitations: live `HKWorkoutSession` heart rate and active energy require a real Apple Watch. In this environment, Xcode reports that the watchOS 26.4 platform is not installed, so the watch target was added but not locally compiled here. Install the watchOS platform from Xcode Settings > Components or test on a paired Apple Watch.

## Running

1. Open the project in Xcode.
2. Select the iOS app scheme.
3. Build and run on iPhone simulator or device.
4. On first launch, seed data is inserted automatically.
5. Use Train to start a quick workout or start from Push/Pull/Legs.
6. Log sets, edit weight/reps/RPE, tap the check button, and finish the workout.

Command-line checks used for this MVP:

```sh
xcodebuild -project 训练.xcodeproj -scheme 训练 -destination 'generic/platform=iOS Simulator' build
xcodebuild test -project 训练.xcodeproj -scheme 训练 -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:训练Tests
```

## Tests

Run the app test target with Xcode Test. Core logic tests cover:

- `VolumeCalculatorTests`
- `OneRepMaxCalculatorTests`
- `WeeklyAggregationTests`
- `UnitConversionTests`
- `SetCompletionTests`

The tests use Swift Testing in `训练Tests/__Tests.swift`.

## Export

Settings includes preview actions for workout CSV, exercise CSV, and all-data JSON. The workout CSV includes:

```text
workout_date, workout_name, exercise_name, set_index, set_type, reps, weight, left_weight, right_weight, rpe, completed_at, volume, notes
```

## MVP Scope

Included in this version:

- Exercise library search and filtering.
- Custom exercise creation and editable exercise details.
- Seeded Push/Pull/Legs routines.
- Start workout from routine or empty quick workout.
- Fast set logging with set type, weight mode aware inputs, reps, RPE, completion, inherited added sets, deletion, and rest timer.
- History detail with heart-rate line chart and zone chart when samples exist.
- Calendar month view with daily workout markers.
- Progress charts for weekly frequency, weekly volume, weekly duration, exercise weight, exercise 1RM, exercise volume, and muscle volume.
- HealthKit authorization, workout write, Health data fetch helpers, and watchOS live workout foundation.

Deferred for later versions:

- Cloud sync.
- Social features.
- AI training recommendations.
- Complex periodization.
- Automatic exercise recognition.
- Video instruction content.
