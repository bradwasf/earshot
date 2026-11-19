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
            Section {
                Toggle(isOn: $detectCalls) {
                    Text("Offer to transcribe when I join a call")
                    Text(
                        "Asks “Start transcribing?” when Zoom, Slack, Teams, Discord, Webex or FaceTime starts using the microphone. Nothing is recorded until you accept."
                    )
                }
                CallEndSetting()
                Toggle(isOn: $openAtLogin) {
                    Text("Open Earshot when I log in")
                    Text(loginNote ?? "Calls are only noticed while Earshot runs. It stays in the menu bar when you close its window.")
                        .foregroundStyle(loginNote != nil ? AnyShapeStyle(Theme.record) : AnyShapeStyle(.secondary))
                }
                .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
            } header: {
                SettingsHeader("Calls", symbol: "phone")
            }

            AppShellSettings(hotKey: model.hotKey)

            Section {
                Picker(selection: $systemSource) {
                    Text("System audio (native tap)").tag("tap")
                    ForEach(inputs.filter(\.isBlackHole)) { device in
                        Text("\(device.name) (loopback device)").tag(device.uid)
                    }
                    Text("Off (microphone only)").tag("none")
                } label: {
                    Text("Other participants")
                    Text("“Them”: whatever this Mac plays.")
                }
                Picker(selection: $microphone) {
                    Text("System default").tag("")
                    ForEach(inputs.filter { !$0.isBlackHole }) { device in
                        Text(device.name).tag(device.uid)
                    }
                    Text("Off").tag("off")
                } label: {
                    Text("My microphone")
                    Text("“Me”: your side of the call.")
                }
                Toggle(isOn: $echoCancellation) {
                    Text("Cancel speaker echo from my microphone")
                    Text("Keeps the other side out of “Me” when you are not on headphones.")
                }
                Toggle(isOn: $echoGuard) {
                    Text("Drop “Me” lines that only repeat the other side")
                }
                Toggle(isOn: $saveAudio) {
                    Text("Save raw audio")
                    Text("audio.m4a in the call’s folder (left = Me, right = Them), so you can play the call back.")
                }
            } header: {
                SettingsHeader("Audio", symbol: "waveform")
            } footer: {
                if !inputs.contains(where: \.isBlackHole) {
                    SettingsFooter(
                        "BlackHole is not installed. It is only needed if the native system-audio tap does not work on your Mac; see the README."
                    )
                }
            }

            Section {
                Picker("Speech model", selection: $asrModel) {
                    ForEach(AsrModelChoice.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Toggle("Tell remote speakers apart (Them 1, Them 2…)", isOn: $diarization)
            } header: {
                SettingsHeader("Transcription", symbol: "text.bubble")
            } footer: {
                SettingsFooter("Changes apply to the next call. A new model downloads once (300–600 MB).")
            }

            Section {
                Toggle("Summarize when a call stops", isOn: $summarize)
                Picker(selection: $summaryModel) {
                    ForEach(summaryChoices, id: \.self) { Text($0).tag($0) }
                } label: {
                    Text("Ollama model")
                    Text("Runs locally at 127.0.0.1:11434. A missing model is pulled automatically.")
                }
                .disabled(!summarize)
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
            } header: {
                SettingsHeader("Summary", symbol: "text.badge.star")
            } footer: {
                SettingsFooter(
                    "Instructions are added to every summary, including Regenerate Summary. The sections (TL;DR, Key points, Decisions, Action items, Open questions) stay the same."
                )
            }

            Section {
                SecureField("Channel webhook", text: $webhook, prompt: Text("https://hooks.slack.com/services/…"))
                    .onSubmit(saveWebhook)
                HStack(spacing: 8) {
                    Button("Save", action: saveWebhook)
                    Button(testingSlack ? "Sending…" : "Send a test message", action: testWebhook)
                        .disabled(testingSlack || SlackWebhook.validated(webhook) == nil)
                    Spacer()
                    if model.slackReady {
                        Button("Remove", role: .destructive) {
                            webhook = ""
                            saveWebhook()
                        }
                    }
                }
            } header: {
                SettingsHeader("Slack", symbol: "number")
            } footer: {
                if let slackNote {
                    SettingsFooter(slackNote, color: slackNoteIsError ? Theme.record : nil)
                } else {
                    SettingsFooter(
                        "Optional. With a webhook, Export › Send to Slack posts a call’s summary to one channel; that post is the only thing Earshot ever sends off this Mac, and only when you choose it. Create one at api.slack.com/apps › your app › Incoming Webhooks. Copy for Slack works without it."
                    )
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text((callsFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .help(callsFolder)
                        Button("Choose…", action: chooseFolder)
                    }
                } label: {
                    Text("Calls folder")
                    Text("transcript.md, summary.md and audio for every call.")
                }
            } header: {
                SettingsHeader("Storage", symbol: "folder")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .tint(Theme.me)
        .frame(width: 540, height: 680)
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

/// A settings section's title, with a small symbol.
struct SettingsHeader: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.inkSoft)
        }
        .labelStyle(TightLabelStyle())
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.ink)
    }
}

/// Helper text under a settings section.
struct SettingsFooter: View {
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(TypeScale.caption)
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
