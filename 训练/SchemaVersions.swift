import Foundation
import SwiftData

/// First versioned snapshot of the LiftLog SwiftData schema.
///
/// All `@Model` types currently used by the app are registered here. When the schema
/// needs an incompatible change (renamed/removed property, split entity, etc.):
///   1. Snapshot the *current* model layout as a new versioned schema (e.g. `SchemaV2`)
///      with its updated type aliases or nested model copies.
///   2. Bump `Self.versionIdentifier` and add the new schema to `LiftLogMigrationPlan`.
///   3. Provide a `MigrationStage` (lightweight or custom) describing how V(N-1) data
///      maps to V(N).
///
/// Until then this enum exists purely to give SwiftData a stable schema identity so an
/// upgrade install can route through the migration plan instead of failing with
/// `loadIssueModelContainer`.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Exercise.self,
            WorkoutRoutine.self,
            RoutineExercise.self,
            WorkoutSession.self,
            WorkoutExercise.self,
            SetRecord.self,
            HeartRateSample.self,
            UserSettings.self,
            BodyMeasurement.self
        ]
    }
}

/// Migration plan registered with the `ModelContainer`. Today there's a single schema
/// version so `stages` is empty; SwiftData will treat any pre-existing on-disk store
/// (including non-versioned stores from before `ef99c95`) as already living at V1.
///
/// Add future versions and `MigrationStage` entries here in chronological order.
enum LiftLogMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
