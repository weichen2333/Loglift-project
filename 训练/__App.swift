import SwiftUI
import SwiftData
import OSLog

@main
struct LiftLogApp: App {
    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 24, weight: .bold)
        ]
        appearance.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: LiftLogMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            // No usable container means no app — log a fault with the full error so
            // Console.app shows the diagnostic before we abort.
            Logger(subsystem: "com.fan.liftlog", category: "SwiftData")
                .fault("Failed to open ModelContainer for SchemaV1: \(error.localizedDescription, privacy: .public)")
            fatalError("Could not create LiftLog ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
