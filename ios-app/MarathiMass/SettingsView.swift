import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Marathi voice · आवाज") {
                    Picker("Voice", selection: $settings.voice) {
                        ForEach(AppSettings.voices, id: \.id) { v in Text(v.label).tag(v.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Text size") {
                    Slider(value: $settings.textSize, in: 18...44, step: 2)
                    Text("प्रभू तुमच्याबरोबर असो.").font(.system(size: settings.textSize))
                }

                Section {
                    TextField("Azure Speech key", text: $settings.azureKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Region (e.g. eastus)", text: $settings.azureRegion)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Option A · Azure key on this phone")
                } footer: {
                    Text("Simplest. Create a free \"Speech\" resource at portal.azure.com and paste KEY 1 and the region here.")
                }

                Section {
                    TextField("Server address (https://…)", text: $settings.serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Access PIN", text: $settings.serverPIN)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Option B · Token server")
                } footer: {
                    Text("If you host the companion web app, enter its address here and the key stays on the server. When a server address is set it is used instead of Option A.")
                }
            }
            .navigationTitle("Settings · सेटिंग्ज")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
