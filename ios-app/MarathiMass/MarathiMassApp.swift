import SwiftUI

@main
struct MarathiMassApp: App {
    @StateObject private var service = TranslationService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(service)
                .preferredColorScheme(.dark)
        }
    }
}
