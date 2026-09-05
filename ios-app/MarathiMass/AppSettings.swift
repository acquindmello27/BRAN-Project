import Foundation
import SwiftUI

/// User settings, persisted on the phone. Either paste the Azure key straight
/// into the app (simplest for a personal app on two phones) or point it at the
/// token server from ../live-translation so the key never lives on the phone.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("azureKey") var azureKey: String = ""
    @AppStorage("azureRegion") var azureRegion: String = "eastus"
    @AppStorage("serverURL") var serverURL: String = ""      // e.g. https://live-translation-marathi.onrender.com
    @AppStorage("serverPIN") var serverPIN: String = ""
    @AppStorage("voice") var voice: String = "mr-IN-AarohiNeural"
    @AppStorage("textSize") var textSize: Double = 28

    static let voices: [(id: String, label: String)] = [
        ("mr-IN-AarohiNeural", "Aarohi (female)"),
        ("mr-IN-ManoharNeural", "Manohar (male)"),
    ]

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            || (!azureKey.trimmingCharacters(in: .whitespaces).isEmpty && !azureRegion.isEmpty)
    }
}
