import AppKit
import Carbon.HIToolbox
import EarshotCore
import SwiftUI

// The app around the call: global shortcut, menu bar, notifications, what happens when a call
// ends, and keyboard navigation of the home list.

extension Preference {
    static let globalShortcut = "globalShortcut"
    static let notifySummaries = "notifySummaries"
    static let callEndAction = "callEndAction"

    static func registerAppShell() {
        UserDefaults.standard.register(defaults: [
            globalShortcut: true,
            notifySummaries: true,
            callEndAction: CallEndAction.ask.rawValue,
        ])
    }
}

/// "When a recorded call ends" in Settings.
enum CallEndAction: String, CaseIterable, Identifiable {
    /// Show the "Stop transcribing?" card.
    case ask
    /// Stop and summarize after a short countdown that "Keep recording" cancels.
    case stop
    /// Do nothing; stop by hand.
    case keep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "Ask me"
        case .stop: return "Stop and summarize"
        case .keep: return "Keep recording"
        }
    }
}

extension CallPrompt {
    /// Seconds of the countdown before a call that ended is stopped automatically.
    static let stopDelay: Double = 5

    /// The card offers to stop the recording because the call looks over.
    var offersToStop: Bool {
        switch self {
        case .ended, .stopping: return true
        case .join, .transcribing, .stopped: return false
        }
    }
}

extension AppModel {
    func setUpAppShell() {
        Preference.registerAppShell()
        notifier.onOpen = { [weak self] folder in self?.showCall(folder: folder) }
        home.install(model: self)
        updateGlobalShortcut()
    }

    var callEndAction: CallEndAction {
        CallEndAction(rawValue: UserDefaults.standard.string(forKey: Preference.callEndAction) ?? "") ?? .ask
    }

    // MARK: Window

    /// The main window, when it exists (it may be closed while Earshot sits in the menu bar).
    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    func showMainWindow() {
        if let openMainWindow {
            openMainWindow()
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings the window forward on a saved call (from a notification or the menu bar).
    func showCall(folder: URL) {
        showMainWindow()
        guard !isRecording, !isBusy, FileManager.default.fileExists(atPath: folder.path) else { return }
        home.select(folder)
        if let call = library.first(where: { $0.folder == folder }) {
            open(call)
        } else {
            // Not listed yet (the library refreshes in the background).
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            guard let loaded = Self.loadDocument(folder, date: created) else { return }
            document = loaded
            tab = loaded.summary != nil ? .summary : .transcript
            screen = .call
        }
    }

    // MARK: Global shortcut

    func updateGlobalShortcut() {
        hotKey.setEnabled(UserDefaults.standard.bool(forKey: Preference.globalShortcut)) { [weak self] in
            self?.toggleFromShortcut()
        }
    }

    /// ⌃⌥⌘R from any app: like pressing Record, with a small card instead of bringing the window up.
    func toggleFromShortcut() {
        let app = Self.callAppForShortcut()
        if isRecording {
            promptPanel.show(.stopped(app), model: self)
            Task { await stop() }
            return
        }
        // A press while Earshot is still getting ready only repeats the first one.
        guard phase != .starting, !hotKey.startPending else { return }
        hotKey.startPending = true
        promptPanel.show(.transcribing(app), model: self)
        Task {
            defer { hotKey.startPending = false }
            // Models may still be loading, or the previous call summarizing: start once that is done.
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
                // The reason is shown in the window.
                promptPanel.dismiss()
                showMainWindow()
            }
        }
    }

    /// The meeting app in front (or holding the microphone), for the card's icon and the call's
    /// placeholder title; otherwise a stand-in named like the Record button would name the call.
    private static func callAppForShortcut() -> CallApp {
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            let app = CallApp.match(bundleID: frontmost)
        {
            return app
        }
        if let app = MicrophoneActivity.callAppsCapturingAudio().sorted(by: { $0.id < $1.id }).first { return app }
        return CallApp(id: "earshot", name: "Earshot", callName: placeholderTitle(), bundlePrefixes: [])
    }

    // MARK: Notifications

    /// Posts "Summary ready" (or "Summary failed") unless the Earshot window is in front.
    func notifySummary(folder: URL, error: Error?) {
        guard UserDefaults.standard.bool(forKey: Preference.notifySummaries),
            !(NSApp.isActive && mainWindow?.isKeyWindow == true)
        else { return }
        let title =
            (document?.folder == folder ? document?.title : nil) ?? CallLibrary.load(folder: folder)?.title
            ?? folder.lastPathComponent
        if let error {
            notifier.summaryFailed(folder: folder, title: title, error: error)
        } else {
            notifier.summaryReady(folder: folder, title: title, summaryMarkdown: CallLibrary.summary(folder: folder))
        }
    }

    // MARK: Menu bar

    /// The newest call with a usable summary.
    var latestSummarizedCall: SavedCall? { library.first { $0.overview != nil } }

    /// "Copy Last Summary for Slack" in the menu bar: the same text as Export › Copy for Slack.
    func copyLatestSummaryForSlack() {
        guard let call = latestSummarizedCall, let loaded = Self.loadDocument(call.folder, date: call.date),
            let summary = loaded.summary,
            let export = SummaryExport(summaryMarkdown: summary, title: loaded.title, detail: loaded.detail)
        else { return NSSound.beep() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("<meta charset=\"utf-8\">" + export.html(.slack), forType: .html)
        pasteboard.setString(export.slackText, forType: .string)
        show(Toast(text: "Summary of “\(loaded.title)” copied — paste it into Slack"))
    }
}

// MARK: - Home list keyboard

/// Keyboard control of the home list (↑/↓, Return, ⌘⌫, ⌘F, Esc) and Esc / ⌘[ to leave a call.
/// Keys are read with a local event monitor so they work whichever control has focus; a text
/// being edited keeps the keys it needs.
@MainActor
final class HomeNavigator: ObservableObject {
    /// The highlighted call (moves with ↑/↓).
    @Published private(set) var selection: URL?
    /// The call that the next ⌘⌫ moves to the Trash (armed by the first press, for 3 s).
    @Published private(set) var armed: URL?
    /// Incremented by ⌘F; the search field takes focus when it changes.
    @Published private(set) var searchFocusRequest = 0
    /// Kept up to date by the search field.
    var searchFocused = false

    private weak var model: AppModel?
    private var monitor: Any?
    private var disarmTask: Task<Void, Never>?

    func install(model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    func select(_ folder: URL?) {
        guard selection != folder else { return }
        selection = folder
        disarm()
    }

    func open(_ call: SavedCall) {
        select(call.folder)
        model?.open(call)
    }

    /// True when the key was handled here (and must not reach the window).
    private func consumes(_ event: NSEvent) -> Bool {
        guard let model, let window = event.window, window.identifier?.rawValue.hasPrefix("main") == true,
            window.attachedSheet == nil
        else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let key = Int(event.keyCode)
        let character = event.charactersIgnoringModifiers?.lowercased()
        let editingText = (window.firstResponder as? NSTextView)?.isEditable == true

        switch model.screen {
        case .home:
            return handleHome(key: key, character: character, flags: flags, editingText: editingText, window: window)
        case .call:
            // Esc or ⌘[ goes back to the list, unless a text is being edited.
            let back = (key == kVK_Escape && flags.isEmpty) || (flags == .command && character == "[")
            guard back, !editingText, !model.isBusy, !model.isRecording else { return false }
            // With the find bar open, Esc closes the bar first (CallReader handles it).
            if key == kVK_Escape && model.reader.findOpen { return false }
            let folder = model.document?.folder
            model.goHome()
            select(folder)
            return true
        case .live:
            return false
        }
    }

    private func handleHome(
        key: Int, character: String?, flags: NSEvent.ModifierFlags, editingText: Bool, window: NSWindow
    ) -> Bool {
        guard let model, !model.library.isEmpty else { return false }
        let calls = model.visibleLibrary
        let selectedIndex = selection.flatMap { folder in calls.firstIndex { $0.folder == folder } }

        switch (key, flags) {
        case (kVK_DownArrow, []), (kVK_UpArrow, []):
            guard !calls.isEmpty else { return true }
            let step = key == kVK_DownArrow ? 1 : -1
            let next = selectedIndex.map { min(max($0 + step, 0), calls.count - 1) } ?? 0
            select(calls[next].folder)
            return true

        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            if let selectedIndex {
                open(calls[selectedIndex])
                return true
            }
            // Return in the search field opens the best match; in the title field it records.
            if searchFocused, editingText, !model.search.trimmingCharacters(in: .whitespaces).isEmpty,
                let first = calls.first
            {
                open(first)
                return true
            }
            return false

        case (kVK_Delete, .command):
            guard let selectedIndex else { return false }
            let folder = calls[selectedIndex].folder
            guard armed == folder else {
                // Same two-step confirmation as the Trash button.
                arm(folder)
                return true
            }
            disarm()
            model.trash(folder)
            let remaining = model.visibleLibrary
            selection = remaining.isEmpty ? nil : remaining[min(selectedIndex, remaining.count - 1)].folder
            return true

        case (kVK_Escape, []):
            if armed != nil {
                disarm()
            } else if !model.search.isEmpty {
                model.search = ""
                if searchFocused { window.makeFirstResponder(nil) }
            } else if searchFocused && editingText {
                window.makeFirstResponder(nil)
            } else if selection != nil {
                select(nil)
            } else {
                return false
            }
            return true

        default:
            if flags == .command, character == "f" {
                searchFocusRequest += 1
                return true
            }
            return false
        }
    }

    private func arm(_ folder: URL) {
        armed = folder
        disarmTask?.cancel()
        disarmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { self?.armed = nil }
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        if armed != nil { armed = nil }
    }
}

// MARK: - Home list

/// Recent calls under day headers, each day one card, with the keyboard selection.
struct RecentCallsList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var navigator: HomeNavigator
    let calls: [SavedCall]
    /// The reader around the home screen's scroll view (a reader inside it cannot scroll it).
    let proxy: ScrollViewProxy

    var body: some View {
        let groups = CallGrouping.byDay(calls)
        // Not lazy, so that ↑/↓ can scroll to any row.
        Group {
            VStack(alignment: .leading, spacing: Space.l) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: 7) {
                            Text(group.title).font(TypeScale.calloutStrong).foregroundStyle(Theme.ink)
                            Text("\(group.calls.count)").font(TypeScale.stamp).foregroundStyle(Theme.inkFaint)
                        }
                        .padding(.leading, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.calls.enumerated()), id: \.element.id) { index, call in
                                    if index > 0 { Hairline().padding(.horizontal, 16) }
                                    CallRow(
                                        call: call, open: { navigator.open(call) }, trash: { model.trash(call.folder) },
                                        selected: navigator.selection == call.folder, armed: navigator.armed == call.folder
                                    )
                                    .id(call.folder)
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: navigator.selection) { _, folder in
                guard let folder else { return }
                // Centred: SwiftUI places a bottom-anchored row about one row below the visible
                // area here, so the armed "Move to Trash?" row could be off screen. Deferred one
                // turn so the scroll view has the new selection's layout.
                DispatchQueue.main.async {
                    withAnimation(Motion.standard) { proxy.scrollTo(folder, anchor: .center) }
                }
            }
            .task {
                // Back from a call: bring the call that was open into view once the list is laid out.
                guard let folder = navigator.selection else { return }
                try? await Task.sleep(nanoseconds: 150_000_000)
                proxy.scrollTo(folder, anchor: .center)
            }
        }
        // Typing starts over: Return in the title field records, ⌘⌫ in a field deletes text.
        .onChange(of: model.search) { _, _ in navigator.select(nil) }
        .onChange(of: model.title) { _, _ in navigator.select(nil) }
        .onChange(of: calls.map(\.folder)) { _, folders in
            if let selection = navigator.selection, !folders.contains(selection) { navigator.select(nil) }
        }
    }
}

/// The home search field; ⌘F focuses it.
struct HomeSearchField: View {
    @Binding var text: String
    @ObservedObject var navigator: HomeNavigator
    @FocusState private var focused: Bool

    var body: some View {
        SearchField(text: $text, prompt: "Search calls", focus: $focused)
            .onChange(of: focused) { _, focused in navigator.searchFocused = focused }
            .onChange(of: navigator.searchFocusRequest) { _, _ in focused = true }
            .help("Search calls (⌘F)")
    }
}

/// Hooks the main window into the app shell (one line in `ContentView`).
struct AppShellHooks: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

// MARK: - Menu bar

/// The menu-bar icon; while recording, a record dot and the elapsed time.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isRecording {
            Image(systemName: "record.circle.fill")
            Text(TranscriptFormat.timestamp(model.elapsed)).monospacedDigit()
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// "Recent Calls" and "Copy Last Summary for Slack" in the menu-bar menu (with a divider after).
struct MenuBarRecentCalls: View {
    @EnvironmentObject private var model: AppModel

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        let calls = model.library.prefix(5)
        if !calls.isEmpty {
            Section("Recent Calls") {
                ForEach(calls) { call in
                    Button("\(call.title) · \(Self.formatter.string(from: call.date))") {
                        model.showCall(folder: call.folder)
                    }
                }
            }
            .disabled(model.isRecording || model.isBusy)
            Button("Copy Last Summary for Slack") { model.copyLatestSummaryForSlack() }
                .disabled(model.latestSummarizedCall == nil)
            Divider()
        }
    }
}

// MARK: - Settings

/// "When a recorded call ends" (in the Calls section of Settings).
struct CallEndSetting: View {
    @AppStorage(Preference.callEndAction) private var action = CallEndAction.ask.rawValue
    @AppStorage(Preference.detectCalls) private var detectCalls = true

    var body: some View {
        Picker(selection: $action) {
            ForEach(CallEndAction.allCases) { Text($0.label).tag($0.rawValue) }
        } label: {
            Text("When a recorded call ends")
            Text(note)
        }
        .disabled(!detectCalls)
    }

    private var note: String {
        switch CallEndAction(rawValue: action) ?? .ask {
        case .ask: return "A card offers “Stop & summarize”; ignoring it keeps recording."
        case .stop:
            return "A card counts down “Stopping in 5 s” first, so a dropped connection does not end the recording. “Keep recording” cancels it."
        case .keep: return "Nothing happens; stop the recording yourself."
        }
    }
}

/// Global shortcut and notifications.
struct AppShellSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var hotKey: GlobalHotKey
    @AppStorage(Preference.globalShortcut) private var globalShortcut = true
    @AppStorage(Preference.notifySummaries) private var notifySummaries = true
    @State private var notificationsDenied = false

    var body: some View {
        Section {
            Toggle(isOn: $globalShortcut) {
                Text("Start and stop recording with \(GlobalHotKey.display)")
                Text(shortcutNote)
                    .foregroundStyle(hotKey.state == .unavailable ? AnyShapeStyle(Theme.record) : AnyShapeStyle(.secondary))
            }
            .onChange(of: globalShortcut) { _, _ in model.updateGlobalShortcut() }
            Toggle(isOn: $notifySummaries) {
                Text("Notify me when a summary is ready")
                Text(
                    notificationsDenied && notifySummaries
                        ? "Notifications are turned off for Earshot in System Settings › Notifications."
                        : "Only while the Earshot window is not in front. Click the notification to open the call."
                )
                .foregroundStyle(notificationsDenied && notifySummaries ? AnyShapeStyle(Theme.caution) : AnyShapeStyle(.secondary))
            }
        } header: {
            SettingsHeader("Shortcut and notifications", symbol: "command")
        }
        .task { notificationsDenied = await model.notifier.isDenied() }
    }

    private var shortcutNote: String {
        switch hotKey.state {
        case .registered:
            return "Works from any app, including your meeting. A small card confirms without taking focus from the call."
        case .unavailable:
            return "Another app already uses \(GlobalHotKey.display), so Earshot could not claim it. Quit that app or change its shortcut, then turn this off and on again."
        case .off:
            return "Earshot’s own window still uses ⌘R."
        }
    }
}
