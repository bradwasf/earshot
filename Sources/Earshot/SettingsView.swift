import EarshotCore
import ServiceManagement
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
    @AppStorage(Preference.detectCalls) private var detectCalls = true
    @AppStorage(Preference.summaryInstructions) private var summaryInstructions = ""

    @State private var inputs: [AudioDeviceInfo] = []
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?
    @State private var webhook = ""
    @State private var slackNote: String?
    @State private var slackNoteIsError = false
    @State private var testingSlack = false

    var body: some View {
        Form {
            Section("Calls") {
                Toggle("Offer to transcribe when I join a call", isOn: $detectCalls)
                Text(
                    "Earshot asks “Start transcribing?” when Zoom, Slack, Teams, Discord, Webex or FaceTime starts using the microphone, and offers to stop when the call ends. Nothing is recorded until you accept."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Open Earshot when I log in", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                Text(loginNote ?? "Earshot can only notice calls while it is running. It stays in the menu bar after you close its window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Slack") {
                SecureField("Channel webhook", text: $webhook, prompt: Text("https://hooks.slack.com/services/…"))
                    .onSubmit(saveWebhook)
                HStack {
                    Button("Save", action: saveWebhook)
                    Button(testingSlack ? "Sending…" : "Send a test message", action: testWebhook)
                        .disabled(testingSlack || SlackWebhook.validated(webhook) == nil)
                    if model.slackReady {
                        Button("Remove") {
                            webhook = ""
                            saveWebhook()
                        }
                    }
                    Spacer()
                }
                Text(
                    slackNote
                        ?? "Optional. With a webhook, Export › Send to Slack posts a call’s summary to one channel. That post is the only thing Earshot ever sends off this Mac, and only when you choose it. Create one at api.slack.com/apps › your app › Incoming Webhooks. “Copy for Slack” works without it."
                )
                .font(.caption)
                .foregroundStyle(slackNote != nil && slackNoteIsError ? AnyShapeStyle(Theme.record) : AnyShapeStyle(.secondary))
            }

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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra instructions for summaries")
                    TextField(
                        "Extra instructions for summaries", text: $summaryInstructions,
                        prompt: Text("e.g. Write in Spanish. Focus on engineering decisions. Them 1 is Priya, Them 2 is Raj."),
                        axis: .vertical
                    )
                    .labelsHidden()
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                }
                Text("Added to every summary, including Regenerate Summary. The sections (TL;DR, Key points, Decisions, Action items, Open questions) stay the same.")
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
        .frame(width: 520, height: 640)
        .onAppear {
            inputs = AudioDevices.inputs()
            webhook = SlackSettings.webhook ?? ""
            openAtLogin = SMAppService.mainApp.status == .enabled
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

    private func setOpenAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = nil
        } catch {
            loginNote = "macOS did not accept that: \(error.localizedDescription) Move Earshot to the Applications folder and try again."
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func saveWebhook() {
        let text = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            SlackSettings.webhook = nil
            slackNote = nil
        } else if SlackWebhook.validated(text) != nil {
            SlackSettings.webhook = text
            (slackNote, slackNoteIsError) = ("Saved in your keychain. Send to Slack is ready.", false)
        } else {
            (slackNote, slackNoteIsError) = (SlackWebhook.Failure.invalidURL.localizedDescription, true)
        }
        model.slackReady = SlackSettings.webhookURL != nil
    }

    private func testWebhook() {
        guard let url = SlackWebhook.validated(webhook) else { return }
        saveWebhook()
        testingSlack = true
        Task {
            do {
                try await SlackWebhook.sendText(
                    "Earshot is connected. Call summaries you choose to send will appear here.", to: url,
                    session: SlackSettings.session)
                (slackNote, slackNoteIsError) = ("Test message sent. Check the channel.", false)
            } catch {
                (slackNote, slackNoteIsError) = (error.localizedDescription, true)
            }
            testingSlack = false
        }
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
