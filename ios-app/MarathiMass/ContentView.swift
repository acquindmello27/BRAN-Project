import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var service: TranslationService
    @ObservedObject private var settings = AppSettings.shared
    @State private var showSettings = false

    private var isBusy: Bool { service.state == .connecting }
    private var isRunning: Bool { service.state != .idle }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.09, blue: 0.16).ignoresSafeArea()
            VStack(spacing: 12) {
                header
                statusLine
                transcript
                bigButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            // First launch with nothing configured: open settings straight away.
            if !settings.isConfigured { showSettings = true }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("थेट भाषांतर").font(.headline)
                Text("English → मराठी · Live translation").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title2).foregroundStyle(.secondary).padding(8)
            }
            .disabled(isRunning)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().frame(width: 10, height: 10)
                .foregroundStyle(statusColor)
                .opacity(service.state == .listening ? 1 : 0.6)
            Text(statusText)
        }
        .font(.title3)
        .foregroundStyle(statusColor)
        .frame(maxWidth: .infinity)
        .animation(.default, value: service.state)
    }

    private var statusColor: Color {
        if service.errorMessage != nil { return .red }
        switch service.state {
        case .listening: return .green
        case .connecting, .reconnecting: return .yellow
        case .idle: return .secondary
        }
    }

    private var statusText: String {
        if let e = service.errorMessage { return "त्रुटी · " + e }
        switch service.state {
        case .idle: return "तयार · Ready"
        case .connecting: return "जोडत आहे… · Connecting"
        case .listening: return "ऐकत आहे… · Listening"
        case .reconnecting: return "पुन्हा जोडत आहे… · Reconnecting"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if service.lines.isEmpty && service.partial.isEmpty {
                        Text("इअरफोन लावा, मग खालचे हिरवे बटण दाबा.\nPut your earphones in, then tap the green button. The English you hear will be spoken to you in Marathi.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    ForEach(Array(service.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: settings.textSize))
                    }
                    if !service.partial.isEmpty {
                        Text(service.partial).font(.system(size: settings.textSize)).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            .onChange(of: service.lines.count) { _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: service.partial) { _ in proxy.scrollTo("bottom") }
        }
    }

    private var bigButton: some View {
        Button {
            Task {
                if isRunning { await service.stop() } else { await service.start() }
            }
        } label: {
            VStack(spacing: 6) {
                Text(isRunning ? "थांबवा" : "सुरू करा").font(.system(size: 44, weight: .bold))
                Text(isRunning ? "Stop" : "Start").font(.title3)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: UIScreen.main.bounds.height * 0.3)
            .background(isRunning ? Color.red : Color.green, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(radius: 12, y: 6)
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
    }
}
