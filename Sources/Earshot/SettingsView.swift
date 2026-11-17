import EarshotCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(Preference.systemSource) private var systemSource = "tap"
    @AppStorage(Preference.microphone) private var microphone = ""
    @AppStorage(Preference.asrModel) private var asrModel = AsrModelChoice.ultra.rawValue
    @AppStorage(Preference.summaryModel) private var summaryModel = Summarizer.defaultModel
    @AppStorage(Preference.saveAudio) private var saveAudio = false
    @AppStorage(Preference.echoCancellation) private var echoCancellation = true
    @AppStorage(Preference.echoGuard) private var echoGuard = true
    @AppStorage(Preference.diarization) private var diarization = true
    @AppStorage(Preference.summarize) private var summarize = true
    @AppStorage(Preference.callsFolder) private var callsFolder = CallFolder.defaultRoot.path

    @State private var inputs: [AudioDeviceInfo] = []

    var body: some View {
        Form {
            Section("Audio") {
                Picker("Other participants", selection: $systemSource) {
                    Text("System audio (native tap)").tag("tap")
                    ForEach(inputs.filter(\.isBlackHole)) { device in
                        Text("\(device.name) (loopback device)").tag(device.uid)
                    }
                    Text("Off (microphone only)").tag("none")
                }
                Picker("My microphone", selection: $microphone) {
                    Text("System default").tag("")
                    ForEach(inputs.filter { !$0.isBlackHole }) { device in
                        Text(device.name).tag(device.uid)
                    }
                    Text("Off").tag("off")
                }
                Toggle("Cancel speaker echo from my microphone", isOn: $echoCancellation)
                Toggle("Drop “Me” lines that only repeat the other side", isOn: $echoGuard)
                Toggle("Save raw audio (audio.m4a: left = Me, right = Them)", isOn: $saveAudio)
                if !inputs.contains(where: \.isBlackHole) {
                    Text("BlackHole is not installed. It is only needed if the native system-audio tap does not work on your Mac; see the README.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Transcription") {
                Picker("Speech model", selection: $asrModel) {
                    ForEach(AsrModelChoice.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Toggle("Tell remote speakers apart (Them 1, Them 2…)", isOn: $diarization)
                Text("Model changes apply to the next call. New models download once (300–600 MB).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Summary") {
                Toggle("Summarize when a call stops", isOn: $summarize)
                Picker("Ollama model", selection: $summaryModel) {
                    ForEach(summaryChoices, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!summarize)
                Text("Runs locally through Ollama at 127.0.0.1:11434. A missing model is pulled automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Calls folder") {
                    HStack {
                        Text(callsFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .font(.ui(13))
        .tint(Theme.me)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            inputs = AudioDevices.inputs()
            Task { await model.refreshSummaryModels() }
        }
        .onChange(of: asrModel) { _, _ in reloadIfIdle() }
        .onChange(of: diarization) { _, _ in reloadIfIdle() }
        .onChange(of: echoCancellation) { _, _ in reloadIfIdle() }
    }

    private var summaryChoices: [String] {
        var choices = model.installedSummaryModels
        if !choices.contains(summaryModel) { choices.insert(summaryModel, at: 0) }
        return choices
    }

    private func reloadIfIdle() {
        guard model.phase == .idle else { return }
        Task { await model.loadModels() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: callsFolder)
        if panel.runModal() == .OK, let url = panel.url { callsFolder = url.path }
    }
}
