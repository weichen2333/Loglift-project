import Foundation
import SwiftData

enum MuscleGroup: String, Codable, CaseIterable, Identifiable {
    case chest = "Chest"
    case back = "Back"
    case legs = "Legs"
    case shoulders = "Shoulders"
    case arms = "Arms"
    case core = "Core"
    case fullBody = "Full Body"

    var id: String { rawValue }
}

enum ExerciseType: String, Codable, CaseIterable, Identifiable {
    case barbell
    case dumbbell
    case machine
    case cable
    case bodyweight
    case kettlebell
    case plateLoaded
    case unilateral
    case cardio
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .barbell: "Barbell"
        case .dumbbell: "Dumbbell"
        case .machine: "Machine"
        case .cable: "Cable"
        case .bodyweight: "Bodyweight"
        case .kettlebell: "Kettlebell"
        case .plateLoaded: "Plate Loaded"
        case .unilateral: "Unilateral"
        case .cardio: "Cardio"
        case .other: "Other"
        }
    }
}

enum WeightMode: String, Codable, CaseIterable, Identifiable {
    case sameWeight
    case leftRightSeparate
    case bodyweight
    case assistedBodyweight
    case machineStack
    case plateLoaded
    case cable
    case timeBased
    case distanceBased

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sameWeight: "Total"
        case .leftRightSeparate: "Left/Right"
        case .bodyweight: "Bodyweight"
        case .assistedBodyweight: "Assisted"
        case .machineStack: "Stack"
        case .plateLoaded: "Plate"
        case .cable: "Cable"
        case .timeBased: "Time"
        case .distanceBased: "Distance"
        }
    }
}

enum SetType: String, Codable, CaseIterable, Identifiable {
    case warmup
    case normal
    case drop
    case failure
    case restPause
    case superset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warmup: "Warm-up"
        case .normal: "Normal"
        case .drop: "Drop"
        case .failure: "Failure"
        case .restPause: "Rest Pause"
        case .superset: "Superset"
        }
    }
}

enum WorkoutSource: String, Codable, CaseIterable {
    case manual
    case routine
    case importedHealthKit
}

enum WorkoutStatus: String, Codable, CaseIterable {
    case planned
    case active
    case paused
    case completed
    case cancelled
}

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case kg
    case lb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kg: "Kilograms"
        case .lb: "Pounds"
        }
    }

    var fieldSuffix: String { rawValue }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }
}

enum AccentColorPreset: String, Codable, CaseIterable, Identifiable {
    case pink
    case blue
    case green
    case orange
    case purple
    case red

    var id: String { rawValue }
}

@Model
final class Exercise {
    @Attribute(.unique) var id: UUID
    var name: String
    var englishName: String?
    var primaryMuscleRaw: String
    var secondaryMuscles: [String]
    var typeRaw: String
    var imageName: String?
    var imageData: Data?
    var instructions: String
    var cautions: String
    var defaultWeightModeRaw: String
    var tracksLeftRightSeparately: Bool
    var isCustom: Bool
    var createdAt: Date
    var updatedAt: Date

    var primaryMuscle: MuscleGroup {
        get { MuscleGroup(rawValue: primaryMuscleRaw) ?? .fullBody }
        set { primaryMuscleRaw = newValue.rawValue }
    }

    var type: ExerciseType {
        get { ExerciseType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    var defaultWeightMode: WeightMode {
        get { WeightMode(rawValue: defaultWeightModeRaw) ?? .sameWeight }
        set { defaultWeightModeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        englishName: String? = nil,
        primaryMuscle: MuscleGroup,
        secondaryMuscles: [MuscleGroup] = [],
        type: ExerciseType,
        imageName: String? = "figure.strengthtraining.traditional",
        imageData: Data? = nil,
        instructions: String = "",
        cautions: String = "",
        defaultWeightMode: WeightMode? = nil,
        tracksLeftRightSeparately: Bool = false,
        isCustom: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.englishName = englishName
        self.primaryMuscleRaw = primaryMuscle.rawValue
        self.secondaryMuscles = secondaryMuscles.map(\.rawValue)
        self.typeRaw = type.rawValue
        self.imageName = imageName
        self.imageData = imageData
        self.instructions = instructions
        self.cautions = cautions
        let mode = defaultWeightMode ?? WeightMode.defaultMode(for: type, isUnilateral: tracksLeftRightSeparately)
        self.defaultWeightModeRaw = mode.rawValue
        self.tracksLeftRightSeparately = tracksLeftRightSeparately
        self.isCustom = isCustom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class WorkoutRoutine {
    @Attribute(.unique) var id: UUID
    var name: String
    var note: String
    @Relationship(deleteRule: .cascade) var exercises: [RoutineExercise]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, note: String = "", exercises: [RoutineExercise] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.note = note
        self.exercises = exercises
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class RoutineExercise {
    @Attribute(.unique) var id: UUID
    var exerciseId: UUID
    var exerciseName: String
    var targetSets: Int
    var targetReps: Int
    var targetWeight: Double
    var restSeconds: Int
    var sortOrder: Int
    var enableWarmupSets: Bool
    var enableRampingWeight: Bool

    init(
        id: UUID = UUID(),
        exerciseId: UUID,
        exerciseName: String,
        targetSets: Int = 3,
        targetReps: Int = 10,
        targetWeight: Double = 0,
        restSeconds: Int = 90,
        sortOrder: Int = 0,
        enableWarmupSets: Bool = false,
        enableRampingWeight: Bool = false
    ) {
        self.id = id
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.targetSets = max(1, targetSets)
        self.targetReps = max(0, targetReps)
        self.targetWeight = max(0, targetWeight)
        self.restSeconds = max(0, restSeconds)
        self.sortOrder = sortOrder
        self.enableWarmupSets = enableWarmupSets
        self.enableRampingWeight = enableRampingWeight
    }
}

@Model
final class WorkoutSession {
    @Attribute(.unique) var id: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var workoutDate: Date
    var sourceRaw: String
    var statusRaw: String
    @Relationship(deleteRule: .cascade) var exercises: [WorkoutExercise]
    @Relationship(deleteRule: .cascade) var heartRateSamples: [HeartRateSample]
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var minHeartRate: Double?
    var activeEnergyKcal: Double?
    var healthKitWorkoutUUID: UUID?
    var note: String

    var source: WorkoutSource {
        get { WorkoutSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var status: WorkoutStatus {
        get { WorkoutStatus(rawValue: statusRaw) ?? .planned }
        set { statusRaw = newValue.rawValue }
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var completedSetCount: Int {
        exercises.flatMap(\.sets).filter(\.isCompleted).count
    }

    var totalSetCount: Int {
        exercises.flatMap(\.sets).count
    }

    var totalReps: Int {
        exercises.flatMap(\.sets).filter(\.isCompleted).reduce(0) { $0 + $1.actualReps }
    }

    var totalVolume: Double {
        exercises.flatMap(\.sets).filter(\.isCompleted).reduce(0) { $0 + VolumeCalculator.volume(for: $1) }
    }

    init(
        id: UUID = UUID(),
        name: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        workoutDate: Date = Date(),
        source: WorkoutSource = .manual,
        status: WorkoutStatus = .active,
        exercises: [WorkoutExercise] = [],
        heartRateSamples: [HeartRateSample] = [],
        averageHeartRate: Double? = nil,
        maxHeartRate: Double? = nil,
        minHeartRate: Double? = nil,
        activeEnergyKcal: Double? = nil,
        healthKitWorkoutUUID: UUID? = nil,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.workoutDate = workoutDate
        self.sourceRaw = source.rawValue
        self.statusRaw = status.rawValue
        self.exercises = exercises
        self.heartRateSamples = heartRateSamples
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.minHeartRate = minHeartRate
        self.activeEnergyKcal = activeEnergyKcal
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.note = note
    }
}

@Model
final class WorkoutExercise {
    @Attribute(.unique) var id: UUID
    var exerciseId: UUID
    var exerciseName: String
    var primaryMuscleRaw: String
    var exerciseTypeRaw: String
    var sortOrder: Int
    var defaultRestSeconds: Int
    var note: String
    @Relationship(deleteRule: .cascade) var sets: [SetRecord]

    var primaryMuscle: MuscleGroup {
        get { MuscleGroup(rawValue: primaryMuscleRaw) ?? .fullBody }
        set { primaryMuscleRaw = newValue.rawValue }
    }

    var exerciseType: ExerciseType {
        get { ExerciseType(rawValue: exerciseTypeRaw) ?? .other }
        set { exerciseTypeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        exerciseId: UUID,
        exerciseName: String,
        primaryMuscle: MuscleGroup,
        exerciseType: ExerciseType,
        sortOrder: Int = 0,
        defaultRestSeconds: Int = 90,
        note: String = "",
        sets: [SetRecord] = []
    ) {
        self.id = id
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.primaryMuscleRaw = primaryMuscle.rawValue
        self.exerciseTypeRaw = exerciseType.rawValue
        self.sortOrder = sortOrder
        self.defaultRestSeconds = max(0, defaultRestSeconds)
        self.note = note
        self.sets = sets
    }
}

@Model
final class SetRecord {
    @Attribute(.unique) var id: UUID
    var exerciseId: UUID
    var setIndex: Int
    var setTypeRaw: String
    var targetReps: Int
    var actualReps: Int
    var weightModeRaw: String
    var weight: Double
    var leftWeight: Double
    var rightWeight: Double
    var bodyweightAdditionalLoad: Double
    var assistanceWeight: Double
    var machineLevel: Int?
    var durationSeconds: Int
    var distanceMeters: Double
    var rpe: Double?
    var isCompleted: Bool
    var completedAt: Date?
    var note: String

    var setType: SetType {
        get { SetType(rawValue: setTypeRaw) ?? .normal }
        set { setTypeRaw = newValue.rawValue }
    }

    var weightMode: WeightMode {
        get { WeightMode(rawValue: weightModeRaw) ?? .sameWeight }
        set { weightModeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        exerciseId: UUID,
        setIndex: Int,
        setType: SetType = .normal,
        targetReps: Int = 10,
        actualReps: Int = 10,
        weightMode: WeightMode = .sameWeight,
        weight: Double = 0,
        leftWeight: Double = 0,
        rightWeight: Double = 0,
        bodyweightAdditionalLoad: Double = 0,
        assistanceWeight: Double = 0,
        machineLevel: Int? = nil,
        durationSeconds: Int = 0,
        distanceMeters: Double = 0,
        rpe: Double? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        note: String = ""
    ) {
        self.id = id
        self.exerciseId = exerciseId
        self.setIndex = max(1, setIndex)
        self.setTypeRaw = setType.rawValue
        self.targetReps = max(0, targetReps)
        self.actualReps = max(0, actualReps)
        self.weightModeRaw = weightMode.rawValue
        self.weight = max(0, weight)
        self.leftWeight = max(0, leftWeight)
        self.rightWeight = max(0, rightWeight)
        self.bodyweightAdditionalLoad = max(0, bodyweightAdditionalLoad)
        self.assistanceWeight = max(0, assistanceWeight)
        self.machineLevel = machineLevel
        self.durationSeconds = max(0, durationSeconds)
        self.distanceMeters = max(0, distanceMeters)
        self.rpe = rpe.map { min(10, max(1, $0)) }
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.note = note
    }

    func toggleCompletion() {
        isCompleted.toggle()
        completedAt = isCompleted ? Date() : nil
    }
}

@Model
final class HeartRateSample {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var bpm: Double

    init(id: UUID = UUID(), timestamp: Date, bpm: Double) {
        self.id = id
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

@Model
final class UserSettings {
    @Attribute(.unique) var id: UUID
    var weightUnitRaw: String
    var defaultRestSeconds: Int
    var autoStartRestTimer: Bool
    var usesRPE: Bool
    var showsWarmupSets: Bool
    var writesWorkoutsToHealth: Bool
    var usesBodyweightForBodyweightVolume: Bool
    var themeRaw: String
    var accentColorRaw: String = AccentColorPreset.pink.rawValue
    var age: Int
    var customMaxHeartRate: Int?
    var bodyweightKg: Double

    var weightUnit: WeightUnit {
        get { WeightUnit(rawValue: weightUnitRaw) ?? .kg }
        set { weightUnitRaw = newValue.rawValue }
    }

    var theme: AppTheme {
        get { AppTheme(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }

    var accentColor: AccentColorPreset {
        get { AccentColorPreset(rawValue: accentColorRaw) ?? .pink }
        set { accentColorRaw = newValue.rawValue }
    }

    var maxHeartRate: Int {
        customMaxHeartRate ?? max(120, 220 - age)
    }

    init(
        id: UUID = UUID(),
        weightUnit: WeightUnit = .kg,
        defaultRestSeconds: Int = 90,
        autoStartRestTimer: Bool = true,
        usesRPE: Bool = true,
        showsWarmupSets: Bool = true,
        writesWorkoutsToHealth: Bool = true,
        usesBodyweightForBodyweightVolume: Bool = false,
        theme: AppTheme = .system,
        accentColor: AccentColorPreset = .pink,
        age: Int = 30,
        customMaxHeartRate: Int? = nil,
        bodyweightKg: Double = 75
    ) {
        self.id = id
        self.weightUnitRaw = weightUnit.rawValue
        self.defaultRestSeconds = max(0, defaultRestSeconds)
        self.autoStartRestTimer = autoStartRestTimer
        self.usesRPE = usesRPE
        self.showsWarmupSets = showsWarmupSets
        self.writesWorkoutsToHealth = writesWorkoutsToHealth
        self.usesBodyweightForBodyweightVolume = usesBodyweightForBodyweightVolume
        self.themeRaw = theme.rawValue
        self.accentColorRaw = accentColor.rawValue
        self.age = min(100, max(12, age))
        self.customMaxHeartRate = customMaxHeartRate
        self.bodyweightKg = max(0, bodyweightKg)
    }
}

@Model
final class BodyMeasurement {
    @Attribute(.unique) var id: UUID
    var date: Date
    var bodyMassKg: Double

    init(id: UUID = UUID(), date: Date = Date(), bodyMassKg: Double) {
        self.id = id
        self.date = date
        self.bodyMassKg = max(0, bodyMassKg)
    }
}

extension WeightMode {
    static func defaultMode(for type: ExerciseType, isUnilateral: Bool = false) -> WeightMode {
        if isUnilateral { return .leftRightSeparate }
        switch type {
        case .barbell: return .sameWeight
        case .dumbbell, .kettlebell, .unilateral: return .leftRightSeparate
        case .bodyweight: return .bodyweight
        case .machine: return .machineStack
        case .plateLoaded: return .plateLoaded
        case .cable: return .cable
        case .cardio: return .distanceBased
        case .other: return .sameWeight
        }
    }

    static func recommendedModes(for type: ExerciseType, isUnilateral: Bool = false) -> [WeightMode] {
        let recommended = defaultMode(for: type, isUnilateral: isUnilateral)
        let all = WeightMode.allCases
        return [recommended] + all.filter { $0 != recommended }
    }

    var setupHint: String {
        switch self {
        case .sameWeight:
            return "Use one total load for the set. Best for barbell lifts and single-stack entries."
        case .leftRightSeparate:
            return "Track left and right loads independently. Best for dumbbells, kettlebells, and unilateral work."
        case .bodyweight:
            return "Track reps plus optional added load."
        case .assistedBodyweight:
            return "Track reps plus assistance load."
        case .machineStack:
            return "Track the machine stack load."
        case .plateLoaded:
            return "Track total plate-loaded machine load."
        case .cable:
            return "Track the cable stack or pin load."
        case .timeBased:
            return "Track duration instead of reps and load."
        case .distanceBased:
            return "Track distance and duration."
        }
    }

    var usesSingleLoadField: Bool {
        switch self {
        case .sameWeight, .machineStack, .plateLoaded, .cable:
            true
        case .leftRightSeparate, .bodyweight, .assistedBodyweight, .timeBased, .distanceBased:
            false
        }
    }
}
