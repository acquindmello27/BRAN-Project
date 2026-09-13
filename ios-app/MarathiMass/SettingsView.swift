import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var service: TranslationService
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

                Section {
                    Picker("Engine", selection: $settings.engine) {
                        Text("Separate text-to-speech").tag("tts")
                        Text("Text-to-speech via SDK player (fallback)").tag("sdkplayer")
                        Text("Built-in voice stream (lower latency)").tag("builtin")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button("Test sound") { service.playTestTone() }
                } header: {
                    Text("Voice engine")
                } footer: {
                    Text("\"Test sound\" plays a short beep through the same path as the Marathi voice. If you can't hear it, the problem is the phone's audio route or volume, not Azure.")
                }

                Section {
                    Picker("Sentence detection", selection: $settings.segmentation) {
                        Text("By meaning (keeps up with continuous speech)").tag("semantic")
                        Text("By pauses in speech").tag("pause")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Sentence detection")
                }

                Section {
                    Picker("Speed", selection: $settings.rate) {
                        Text("Normal").tag(1.0)
                        Text("Slightly faster").tag(1.1)
                        Text("Faster").tag(1.2)
                        Text("Fastest").tag(1.35)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Speaking speed (separate text-to-speech only)")
                } footer: {
                    Text("Marathi sentences are longer than the English, so a slightly faster voice keeps the audio from falling behind.")
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
