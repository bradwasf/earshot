import AVFoundation
import AppKit
import EarshotCore
import SwiftUI

/// User preferences, persisted in UserDefaults.
enum Preference {
    static let systemSource = "systemSource"  // "tap", "none", or a device UID
    static let microphone = "microphone"  // "" = system default, "off", or a device UID
    static let asrModel = "asrModel"
    static let summaryModel = "summaryModel"
    static let saveAudio = "saveAudio"
    static let echoCancellation = "echoCancellation"
    static let echoGuard = "echoGuard"
    static let diarization = "diarization"
    static let summarize = "summarize"
    static let callsFolder = "callsFolder"
    static let detectCalls = "detectCalls"

    static func register() {
        UserDefaults.standard.register(defaults: [
            systemSource: "tap",
            microphone: "",
            asrModel: AsrModelChoice.ultra.rawValue,
            summaryModel: Summarizer.defaultModel,
            saveAudio: false,
            echoCancellation: true,
            echoGuard: true,
            diarization: true,
            summarize: true,
            callsFolder: CallFolder.defaultRoot.path,
            detectCalls: true,
        ])
    }
}

/// Append-only diagnostics log at ~/Library/Logs/Earshot/earshot.log (never contains transcript text).
enum Log {
    private static let url: URL = {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Earshot")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("earshot.log")
    }()
    private static let queue = DispatchQueue(label: "earshot.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// A block of talk as drawn in the transcript (live or saved).
struct DisplayTurn: Identifiable, Equatable {
    let id: String
    let label: String
    let time: String
    let text: String
    /// 0 = Me, 1… = remote speakers (see `Theme.tone`).
    let tone: Int
    /// Saved calls: Earshot's label for the speaker ("Them 2"), even after it was named.
    var originalLabel: String? = nil
    /// Saved calls: seconds into the call.
    var start: Double? = nil
}

/// A finished call shown in the window (just recorded, or opened from the library).
struct CallDocument: Equatable {
    var folder: URL
    var title: String
    var detail: String
    var turns: [DisplayTurn]
    var summary: String?
    /// Each speaker's share of the talking.
    var talk: [TalkShare] = []
    /// "42:10", as written in transcript.md.
    var durationText: String? = nil
}

/// A short confirmation shown at the bottom of the window ("Copied — paste it into Slack").
struct Toast: Equatable {
    let id = UUID()
    let text: String
    var symbol = "checkmark.circle.fill"
}

/// What the floating prompt in the corner of the screen is asking.
enum CallPrompt: Equatable {
    /// A meeting app joined a call: offer to transcribe it.
    case join(CallApp)
    /// The call being recorded seems to be over: offer to stop.
    case ended(CallApp)
    /// Confirmation after accepting `join` (or starting with the global shortcut).
    case transcribing(CallApp)
    /// The call ended and "When a recorded call ends" is set to stop: a short countdown that
    /// "Keep recording" cancels.
    case stopping(CallApp)
    /// Confirmation after stopping with the global shortcut.
    case stopped(CallApp)
}

/// Rolling input levels for the waveform ribbon. Kept apart from `AppModel` so that twenty-odd
/// meter updates per second redraw only the ribbon, not the transcript.
@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var me: [Float] = []
    @Published private(set) var them: [Float] = []
    private static let capacity = 400

    func push(_ channel: Channel, _ level: Float) {
        let value = Self.normalized(level)
        switch channel {
        case .me:
            me.append(value)
            if me.count > Self.capacity { me.removeFirst(me.count - Self.capacity) }
        case .them:
            them.append(value)
            if them.count > Self.capacity { them.removeFirst(them.count - Self.capacity) }
        }
    }

    func reset() {
        me = []
        them = []
    }

    var latest: Float { max(me.last ?? 0, them.last ?? 0) }

    /// RMS → 0…1 on a −60…−10 dBFS scale.
    static func normalized(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(level) + 60) / 50))
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading(String)
        case failed(String)
        case idle
        case starting
        case recording
        case finishing(String)
    }

    enum Screen: Equatable {
        /// Recent calls, ready to record.
        case home
        /// A recording in progress.
        case live
        /// A finished call (`document`).
        case call
    }

    enum Tab: String, CaseIterable {
        case transcript = "Transcript"
        case summary = "Summary"
    }

    @Published var phase: Phase = .loading("Loading models…")
    @Published var screen: Screen = .home
    @Published var tab: Tab = .transcript {
        didSet { reader.tabChanged(to: tab) }
    }
    /// Title typed for the next recording.
    @Published var title = ""
    @Published var liveTurns: [DisplayTurn] = []
    @Published var partials: [Channel: String] = [:]
    @Published var elapsed: Double = 0
    @Published var warnings: [String] = []
    @Published var document: CallDocument? {
        didSet { reader.documentChanged(from: oldValue, to: document) }
    }
    @Published var library: [SavedCall] = []
    @Published var status = ""
    @Published var heardSystemAudio = false
    @Published var installedSummaryModels: [String] = []
    /// Filters the list of recent calls.
    @Published var search = ""
    @Published var toast: Toast?
    /// True when a Slack webhook is saved, so "Send to Slack" can post.
    @Published var slackReady = false
    @Published var sendingToSlack = false

    let meter = MeterModel()
    /// Find, playback and speaker names for the finished call on screen.
    let reader = CallReader()

    private var segments: [TranscriptSegment] = []
    private var liveFolder: URL?
    private var models: SpeechModels?
    private var session: CallSession?
    private var timer: Timer?
    private var startedAt = Date()
    private var autoStopAfter: Double?
    /// Loudest input level seen per channel during the current call (for the diagnostics log).
    private var peakLevels: [Channel: Float] = [:]
    private var exitWhenDone = false
    private var detector = CallDetector()
    private var watchTimer: Timer?
    private var toastTask: Task<Void, Never>?
    let promptPanel = PromptPanelController()
    // App shell (AppShell.swift): global shortcut, notifications, home-list keyboard.
    let hotKey = GlobalHotKey()
    let notifier = SummaryNotifier()
    let home = HomeNavigator()
    /// Opens (or brings forward) the main window; set by the window's view.
    var openMainWindow: (() -> Void)?

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool {
        switch phase {
        case .loading, .starting, .finishing: return true
        default: return false
        }
    }

    private var callsRoot: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: Preference.callsFolder) ?? CallFolder.defaultRoot.path)
    }

    init() {
        Preference.register()
        parseLaunchArguments()
        refreshLibrary()
        Task { await loadModels() }
        Task { await refreshSummaryModels() }
        slackReady = SlackSettings.webhookURL != nil
        startWatchingForCalls()
        setUpAppShell()
    }

    // MARK: - Models

    private var modelOptions: SpeechModelOptions {
        let defaults = UserDefaults.standard
        return SpeechModelOptions(
            asr: AsrModelChoice(rawValue: defaults.string(forKey: Preference.asrModel) ?? "") ?? .ultra,
            diarization: defaults.bool(forKey: Preference.diarization),
            echoCancellation: defaults.bool(forKey: Preference.echoCancellation))
    }

    func loadModels() async {
        let options = modelOptions
        if let models, models.options == options { return }
        phase = .loading("Loading models…")
        do {
            let loaded = try await SpeechModels.load(options) { message in
                Task { @MainActor in
                    if case .loading = self.phase { self.phase = .loading(message) }
                }
            }
            models = loaded
            phase = .idle
            status = "Ready"
            Log.write("models loaded: \(options.asr.rawValue)")
            if autoStart {
                autoStart = false
                await start()
            }
        } catch {
            phase = .failed("Could not load the speech models: \(error.localizedDescription)")
            Log.write("model load failed: \(error.localizedDescription)")
        }
    }

    func refreshSummaryModels() async {
        installedSummaryModels = await OllamaClient().installedModels().sorted()
    }

    // MARK: - Library

    func refreshLibrary() {
        let root = callsRoot
        Task.detached(priority: .userInitiated) {
            let calls = CallLibrary.list(root: root)
            await MainActor.run { self.library = calls }
        }
    }

    func open(_ call: SavedCall) {
        guard !isRecording, let loaded = Self.loadDocument(call.folder, date: call.date) else { return }
        document = loaded
        tab = loaded.summary != nil ? .summary : .transcript
        // Opened from a search: show the query in the call, on the tab where it matches.
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { tab = reader.find(query, in: loaded, preferring: tab) }
        screen = .call
    }

    /// Recent calls narrowed by the search field.
    var visibleLibrary: [SavedCall] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? library : library.filter { $0.matches(query) }
    }

    func goHome() {
        guard !isRecording else { return }
        document = nil
        screen = .home
        refreshLibrary()
    }

    static func loadDocument(_ folder: URL, date: Date) -> CallDocument? {
        guard let loaded = CallLibrary.load(folder: folder) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy · HH:mm"
        var detail = formatter.string(from: date)
        if let duration = loaded.duration { detail += " · \(duration)" }
        let turns = loaded.turns.map {
            DisplayTurn(
                id: "saved-\($0.id)", label: $0.label, time: $0.time, text: $0.text,
                tone: Theme.tone(channel: $0.channel, speaker: $0.speaker),
                originalLabel: $0.originalLabel.isEmpty ? nil : $0.originalLabel, start: TranscriptFormat.seconds($0.time))
        }
        return CallDocument(
            folder: folder, title: loaded.title, detail: detail, turns: turns, summary: CallLibrary.summary(folder: folder),
            talk: TalkTime.shares(loaded.turns, duration: loaded.duration.flatMap(TranscriptFormat.seconds)),
            durationText: loaded.duration)
    }

    // MARK: - Recording

    func toggle() {
        Task {
            if isRecording {
                await stop()
            } else if phase == .idle {
                if screen == .call { title = "" }
                await start()
            }
        }
    }

    /// `placeholder` names the call until the summary proposes a title ("Slack huddle").
    func start(placeholder: String? = nil) async {
        await loadModels()
        guard phase == .idle, let models else { return }
        // Stop any playback first: the system-audio tap would transcribe it.
        reader.player.pause()
        phase = .starting
        if case .join = promptPanel.current { promptPanel.dismiss() }
        let defaults = UserDefaults.standard

        // Microphone permission (the system-audio prompt appears when the tap opens).
        var captureMicrophone = defaults.string(forKey: Preference.microphone) != "off"
        var startWarnings: [String] = []
        if captureMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                captureMicrophone = false
                startWarnings.append(
                    "Microphone access is off, so only the other side is transcribed. Enable Earshot in System Settings › Privacy & Security › Microphone."
                )
            }
        }

        let systemAudio: SystemAudioChoice
        switch defaults.string(forKey: Preference.systemSource) ?? "tap" {
        case "tap": systemAudio = .tap
        case "none": systemAudio = .none
        case let uid:
            if AudioDevices.device(uid: uid) != nil {
                systemAudio = .device(uid: uid)
            } else {
                systemAudio = .tap
                startWarnings.append("The selected system-audio device is not connected; using the native tap instead.")
            }
        }

        let typedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let microphoneUID = defaults.string(forKey: Preference.microphone).flatMap { $0.isEmpty || $0 == "off" ? nil : $0 }
        let config = SessionConfig(
            title: typedTitle.isEmpty ? (placeholder ?? Self.placeholderTitle()) : typedTitle,
            titleIsPlaceholder: typedTitle.isEmpty,
            root: callsRoot,
            systemAudio: systemAudio,
            captureMicrophone: captureMicrophone,
            microphoneUID: microphoneUID,
            saveAudio: defaults.bool(forKey: Preference.saveAudio),
            echoTextGuard: defaults.bool(forKey: Preference.echoGuard))

        segments = []
        liveTurns = []
        partials = [:]
        warnings = startWarnings
        heardSystemAudio = false
        elapsed = 0
        peakLevels = [:]
        meter.reset()

        let session = CallSession(config: config, models: models) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try await session.start()
        } catch {
            phase = .idle
            warnings.append("Could not start recording: \(error.localizedDescription)")
            Log.write("start failed: \(error.localizedDescription)")
            return
        }
        self.session = session
        liveFolder = await session.folderURL
        startedAt = Date()
        document = nil
        tab = .transcript
        screen = .live
        phase = .recording
        status = "Saving to \(liveFolder?.lastPathComponent ?? "…") as you talk"
        Log.write("recording started: system=\(systemAudio) mic=\(captureMicrophone)")

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                if let limit = self.autoStopAfter, self.elapsed >= limit {
                    self.autoStopAfter = nil
                    await self.stop()
                }
            }
        }
    }

    func stop() async {
        guard phase == .recording, let session else { return }
        phase = .finishing("Finishing transcript…")
        if promptPanel.current?.offersToStop == true { promptPanel.dismiss() }
        timer?.invalidate()
        timer = nil
        guard var result = await session.stop() else {
            phase = .idle
            screen = .home
            return
        }
        self.session = nil
        partials = [:]
        meter.reset()
        title = ""
        document = Self.loadDocument(result.folder.url, date: result.startedAt)
        screen = .call
        tab = .transcript
        Log.write(
            "recording stopped: \(Int(result.duration)) s, \(result.segments.count) lines, word latency "
                + result.metrics.wordLatency.map { "\($0.key) p50 \(String(format: "%.2f", $0.value.p50)) p95 \(String(format: "%.2f", $0.value.p95))" }
                .sorted().joined(separator: ", ")
                + "; peak input level " + Channel.allCases.map {
                    "\($0.rawValue) \(peakLevels[$0].map { String(format: "%.0f dBFS", 20 * log10(Double(max($0, 1e-7)))) } ?? "no signal")"
                }.joined(separator: ", "))

        if UserDefaults.standard.bool(forKey: Preference.summarize), !result.segments.isEmpty {
            let model = UserDefaults.standard.string(forKey: Preference.summaryModel) ?? Summarizer.defaultModel
            phase = .finishing("Summarizing with \(model)…")
            tab = .summary
            var summaryError: Error?
            do {
                let written = try await CallSummary.write(for: &result, model: model) { message in
                    Task { @MainActor in
                        if case .finishing = self.phase { self.phase = .finishing(message) }
                    }
                }
                status = "Transcript and summary saved"
                Log.write("summary written with \(model) in \(Int(written.seconds)) s")
            } catch {
                CallSummary.writeFailure(folder: result.folder.url, title: result.title, error: error)
                summaryError = error
                warnings.append(error.localizedDescription)
                status = "Transcript saved (the summary failed)"
                Log.write("summary failed: \(error.localizedDescription)")
            }
            // The summary may have renamed the call; show what is on disk now.
            document = Self.loadDocument(result.folder.url, date: result.startedAt) ?? document
            notifySummary(folder: result.folder.url, error: summaryError)
        } else {
            status = result.segments.isEmpty ? "No speech was detected" : "Transcript saved"
        }
        phase = .idle
        refreshLibrary()
        if exitWhenDone { NSApp.terminate(nil) }
    }

    func regenerateSummary() {
        guard let folder = document?.folder, phase == .idle else { return }
        let model = UserDefaults.standard.string(forKey: Preference.summaryModel) ?? Summarizer.defaultModel
        phase = .finishing("Summarizing with \(model)…")
        tab = .summary
        document?.summary = nil
        Task {
            do {
                let written = try await CallSummary.regenerate(folder: folder, model: model) { message in
                    Task { @MainActor in
                        if case .finishing = self.phase { self.phase = .finishing(message) }
                    }
                }
                document?.summary = written.markdown
                status = "Summary regenerated"
                notifySummary(folder: folder, error: nil)
            } catch {
                document?.summary = CallLibrary.summary(folder: folder)
                warnings.append(error.localizedDescription)
                notifySummary(folder: folder, error: error)
            }
            phase = .idle
            refreshLibrary()
        }
    }

    func revealInFinder() {
        if let folder = document?.folder ?? liveFolder, FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            openCallsFolder()
        }
    }

    func openCallsFolder() {
        try? FileManager.default.createDirectory(at: callsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(callsRoot)
    }

    /// Called on quit: never lose an in-progress call.
    func stopForTermination() async {
        if isRecording, let session {
            timer?.invalidate()
            _ = await session.stop()
        }
    }

    // MARK: - Editing saved calls

    /// Retitles the call on screen (headings in both files, and the folder name).
    func renameCurrentCall(to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .idle, let current = document, !title.isEmpty, title != current.title else { return }
        do {
            let folder = try CallLibrary.rename(folder: current.folder, to: title)
            document?.folder = folder
            document?.title = title
            document?.summary = CallLibrary.summary(folder: folder)
            refreshLibrary()
            show(Toast(text: "Renamed"))
        } catch {
            warnings.append("Could not rename the call: \(error.localizedDescription)")
        }
    }

    /// Speakers can be named in a finished call, but not while a call is recorded or summarized.
    var canEditSpeakers: Bool {
        switch phase {
        case .idle, .loading, .failed: return document != nil
        case .starting, .recording, .finishing: return false
        }
    }

    /// Names a speaker of the call on screen (nil or empty reverts to Earshot's label) in
    /// transcript.md and summary.md. Returns a message to show when that is not possible.
    func renameSpeaker(_ label: String, to name: String?) -> String? {
        guard canEditSpeakers, let current = document else { return "Names can be changed once the call is saved." }
        do {
            let shown = try SpeakerNames.rename(folder: current.folder, label: label, to: name)
            if var updated = Self.loadDocument(current.folder, date: Date()) {
                updated.detail = current.detail
                document = updated
            }
            refreshLibrary()
            show(Toast(text: shown == label ? "Back to “\(label)”" : "\(label) is now “\(shown)”"))
            Log.write("speaker renamed")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Copies one turn: its text, or "[12:03] Priya: …".
    func copyTurn(_ turn: DisplayTurn, withSpeaker: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(withSpeaker ? "[\(turn.time)] \(turn.label): \(turn.text)" : turn.text, forType: .string)
        show(Toast(text: "Copied"))
    }

    /// Moves a saved call to the Trash.
    func trash(_ folder: URL) {
        guard phase == .idle || document?.folder != folder else { return }
        do {
            try CallLibrary.trash(folder: folder)
            if document?.folder == folder {
                document = nil
                screen = .home
            }
            library.removeAll { $0.folder == folder }
            refreshLibrary()
            show(Toast(text: "Moved to the Trash", symbol: "trash.fill"))
        } catch {
            warnings.append("Could not move the call to the Trash: \(error.localizedDescription)")
        }
    }

    // MARK: - Export

    enum ExportKind {
        case slack, markdown, transcript
    }

    /// The summary on screen, ready to export (nil while there is no usable summary).
    var summaryExport: SummaryExport? {
        guard let document, let summary = document.summary else { return nil }
        return SummaryExport(summaryMarkdown: summary, title: document.title, detail: document.detail)
    }

    var canExportTranscript: Bool { !(document?.turns.isEmpty ?? true) }

    func copy(_ kind: ExportKind) {
        let pasteboard = NSPasteboard.general
        switch kind {
        case .slack:
            guard let export = summaryExport else { return }
            pasteboard.clearContents()
            // Slack's composer keeps the rich text; where it pastes as plain text, the fallback
            // is already in Slack's own markup.
            pasteboard.setString("<meta charset=\"utf-8\">" + export.html(.slack), forType: .html)
            pasteboard.setString(export.slackText, forType: .string)
            show(Toast(text: "Summary copied — paste it into Slack"))
        case .markdown:
            guard let export = summaryExport else { return }
            pasteboard.clearContents()
            pasteboard.setString("<meta charset=\"utf-8\">" + export.html(.document), forType: .html)
            pasteboard.setString(export.markdown, forType: .string)
            show(Toast(text: "Summary copied"))
        case .transcript:
            guard let document, !document.turns.isEmpty else { return }
            let lines = document.turns.map { "[\($0.time)] \($0.label): \($0.text)" }
            pasteboard.clearContents()
            pasteboard.setString(([document.title, document.detail, ""] + lines).joined(separator: "\n"), forType: .string)
            show(Toast(text: "Transcript copied"))
        }
    }

    /// Posts the summary on screen to the saved Slack webhook.
    func sendToSlack() {
        guard !sendingToSlack, let export = summaryExport, let url = SlackSettings.webhookURL else { return }
        sendingToSlack = true
        Task {
            do {
                try await SlackWebhook.send(export, to: url, session: SlackSettings.session)
                show(Toast(text: "Posted to Slack", symbol: "paperplane.fill"))
                Log.write("summary posted to Slack")
            } catch {
                warnings.append(error.localizedDescription)
                Log.write("Slack post failed: \(error.localizedDescription)")
            }
            sendingToSlack = false
        }
    }

    /// True when the Grok Bot app is installed (it handles `grokbot://` links).
    var grokBotInstalled: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "grokbot://app/v1/open")!) != nil
    }

    /// Opens Grok Bot with a prompt about this call. Its deep link caps the prompt at 1,000
    /// characters, so the prompt points at the call's saved transcript.md and summary.md
    /// rather than carrying the whole transcript.
    func sendToGrokBot() {
        guard let document, canExportTranscript else { return }
        let transcript = document.folder.appendingPathComponent("transcript.md").path
        let summary = document.folder.appendingPathComponent("summary.md")
        var lines = ["Here is a call I transcribed with Earshot: \"\(document.title)\" (\(document.detail))."]
        lines.append("Full transcript, with speakers and times: \(transcript)")
        // Named speakers (the transcript already uses the names; say which one is me).
        var named: [String] = []
        for turn in document.turns where turn.originalLabel != nil && turn.label != turn.originalLabel {
            let entry = turn.originalLabel == "Me" ? "\(turn.label) (me)" : turn.label
            if !named.contains(entry) { named.append(entry) }
        }
        if !named.isEmpty { lines.append("Speakers: \(named.joined(separator: ", ")).") }
        if document.summary != nil { lines.append("Summary: \(summary.path)") }
        lines.append("Read them, then help me with follow-ups from this call.")
        guard let url = GrokBotLink.prompt(lines.joined(separator: " ")) else { return }
        NSWorkspace.shared.open(url)
        show(Toast(text: "Opened in Grok Bot", symbol: "paperplane.fill"))
        Log.write("call sent to Grok Bot")
    }

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled, self.toast == toast { self.toast = nil }
        }
    }

    // MARK: - Call detection

    /// Polls Core Audio for meeting apps holding the microphone. This reads which processes
    /// capture audio, never the audio itself, and needs no permission.
    private func startWatchingForCalls() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForCalls() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func checkForCalls() {
        guard UserDefaults.standard.bool(forKey: Preference.detectCalls) else {
            if !detector.active.isEmpty || promptPanel.current != nil {
                detector.reset()
                promptPanel.dismiss()
            }
            return
        }
        let apps = MicrophoneActivity.callAppsCapturingAudio(apps: watchedApps)
        for event in detector.update(using: apps, now: ProcessInfo.processInfo.systemUptime) {
            switch event {
            case .joined(let app):
                Log.write("call joined: \(app.id)")
                // One offer per call, and none while a recording is already running.
                if !isRecording && phase != .starting {
                    present(.join(app))
                } else if isRecording, promptPanel.current?.offersToStop == true {
                    // The call came back after a short drop: withdraw the offer to stop.
                    promptPanel.dismiss()
                }
            case .ended(let app):
                Log.write("call ended: \(app.id)")
                if promptPanel.current == .join(app) { promptPanel.dismiss() }
                if isRecording && detector.active.isEmpty {
                    switch callEndAction {
                    case .ask: present(.ended(app))
                    case .stop: present(.stopping(app))
                    case .keep: break
                    }
                }
            }
        }
    }

    private func present(_ prompt: CallPrompt) {
        promptPanel.show(prompt, model: self)
        guard autoAcceptPrompts else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard promptPanel.current == prompt else { return }
            switch prompt {
            case .join(let app): acceptCall(app)
            case .ended, .stopping: acceptCallEnded()
            case .transcribing, .stopped: break
            }
        }
    }

    /// "Transcribe" on the join prompt.
    func acceptCall(_ app: CallApp) {
        promptPanel.show(.transcribing(app), model: self)
        Task {
            // A previous call may still be summarizing; recording starts as soon as that is done.
            var waited = 0.0
            while isBusy, waited < 600 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            }
            if phase == .idle {
                if screen == .call { title = "" }
                await start(placeholder: app.callName)
            }
            if !isRecording {
                // Something went wrong (shown as a warning in the window): bring it forward.
                promptPanel.dismiss()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// "Stop & summarize" on the call-ended prompt.
    func acceptCallEnded() {
        promptPanel.dismiss()
        Task { await stop() }
    }

    private var watchedApps: [CallApp] { CallApp.known + extraWatchedApps }

    // MARK: - Events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .segment(let segment):
            let index = segments.firstIndex { $0.start > segment.start } ?? segments.count
            segments.insert(segment, at: index)
            rebuildLiveTurns()
        case .partial(let channel, let text, _):
            if partials[channel] != text { partials[channel] = text }
        case .level(let channel, let level):
            meter.push(channel, level)
            peakLevels[channel] = max(peakLevels[channel] ?? 0, level)
            if channel == .them && level > 0.0005 && !heardSystemAudio { heardSystemAudio = true }
        case .warning(let message):
            warnings.append(message)
            Log.write("warning: \(message)")
        }
    }

    private func rebuildLiveTurns() {
        // Same rule as the saved transcript: a remote voice gets its own label once it has
        // spoken for three seconds.
        var speakerTime: [Int: Double] = [:]
        for segment in segments where segment.channel == .them {
            if let speaker = segment.speaker { speakerTime[speaker, default: 0] += segment.end - segment.start }
        }
        let remoteSpeakers = speakerTime.values.filter { $0 >= 3 }.count
        liveTurns = TranscriptFormat.turns(segments, remoteSpeakers: remoteSpeakers).map {
            DisplayTurn(
                id: $0.id, label: $0.label, time: TranscriptFormat.timestamp($0.start), text: $0.text,
                tone: remoteSpeakers > 1 ? Theme.tone(channel: $0.channel, speaker: $0.speaker) : ($0.channel == .me ? 0 : 1))
        }
    }

    // MARK: - Helpers

    /// "Zoom call", "FaceTime call"… when a meeting app is running; otherwise "Call".
    static func placeholderTitle() -> String {
        let apps: [(bundle: String, name: String)] = [
            ("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams"), ("com.microsoft.teams", "Teams"),
            ("com.apple.FaceTime", "FaceTime"), ("com.cisco.webexmeetingsapp", "Webex"),
            ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
        ]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            let match = apps.first(where: { $0.bundle == frontmost })
        {
            return "\(match.name) call"
        }
        if let match = apps.first(where: { running.contains($0.bundle) && $0.name != "Slack" && $0.name != "Discord" }) {
            return "\(match.name) call"
        }
        return "Call"
    }

    // Launch arguments used by the end-to-end test:
    //   --autostart --stop-after 60 --title "X" --exit-when-done --appearance light|dark --open-latest
    //   --watch-app <bundle-id-prefix>   also treat that app as a meeting app (tests the detector)
    //   --simulate-prompt join|ended|transcribing   show the floating prompt at launch (screenshots)
    private var autoStart = false
    //   --accept-prompts                 answer every prompt with its main button (end-to-end test)
    //   --send-to-grok                   with --open-latest, run Export › Send to Grok Bot at launch
    //   --search <query>                 type into the home search (with --open-latest: open the call from it)
    //   --find <query>                   with --open-latest, open the find bar on that query
    //   --seek <seconds>                 with --open-latest, move the recording's playhead there (no sound)
    //   --name-speaker <turn number>     with --open-latest, open the speaker-name editor on that turn
    private var extraWatchedApps: [CallApp] = []
    private var autoAcceptPrompts = false

    private func parseLaunchArguments() {
        let arguments = CommandLine.arguments
        autoStart = arguments.contains("--autostart")
        exitWhenDone = arguments.contains("--exit-when-done")
        if let index = arguments.firstIndex(of: "--stop-after"), index + 1 < arguments.count {
            autoStopAfter = Double(arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--title"), index + 1 < arguments.count {
            title = arguments[index + 1]
        }
        autoAcceptPrompts = arguments.contains("--accept-prompts")
        if let index = arguments.firstIndex(of: "--watch-app"), index + 1 < arguments.count {
            extraWatchedApps = [CallApp(id: "test", name: "Test", callName: "Test call", bundlePrefixes: [arguments[index + 1]])]
        }
        if let index = arguments.firstIndex(of: "--simulate-prompt"), index + 1 < arguments.count {
            let kind = arguments[index + 1]
            let app = CallApp.known.first { $0.id == (arguments.dropFirst(index + 2).first ?? "slack") } ?? CallApp.known[1]
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                promptPanel.show(kind == "ended" ? .ended(app) : kind == "transcribing" ? .transcribing(app) : .join(app), model: self)
            }
        }
        if let index = arguments.firstIndex(of: "--search"), index + 1 < arguments.count {
            search = arguments[index + 1]
        }
        if arguments.contains("--open-latest") {
            if let latest = CallLibrary.list(root: callsRoot).first { open(latest) }
            if arguments.contains("--transcript") { tab = .transcript }
            if let index = arguments.firstIndex(of: "--find"), index + 1 < arguments.count {
                reader.showFind()
                reader.query = arguments[index + 1]
            }
            if let index = arguments.firstIndex(of: "--seek"), index + 1 < arguments.count,
                let seconds = Double(arguments[index + 1])
            {
                reader.player.seek(to: seconds)
            }
            if let index = arguments.firstIndex(of: "--name-speaker"), index + 1 < arguments.count,
                let number = Int(arguments[index + 1])
            {
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    reader.renamingTurn = "saved-\(number)"
                }
            }
            if arguments.contains("--send-to-grok") {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    sendToGrokBot()
                }
            }
        }
    }
}
