import EarshotCore
import SwiftUI

/// The single window: header (title + record control), then home, live call or finished call,
/// then a footer of quiet actions.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            if !model.warnings.isEmpty {
                WarningsView().transition(.opacity.combined(with: .move(edge: .top)))
            }
            Group {
                switch model.screen {
                case .home: HomeView()
                case .live: LiveView()
                case .call: CallView().environmentObject(model.reader)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            FooterView()
        }
        .frame(minWidth: 480, minHeight: 520)
        .background(Theme.canvas.ignoresSafeArea())
        .background(WindowChrome())
        .overlay(alignment: .top) {
            // Wordmark in the (hidden) title bar.
            Text("EARSHOT")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.6)
                .foregroundStyle(Theme.inkFaint)
                .frame(height: 28)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, toastOffset)
                    .transition(.opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.96)))
            }
        }
        .tint(Theme.focus)
        .modifier(AppShellHooks())
        .animation(Motion.screen, value: model.screen)
        .animation(Motion.standard, value: model.toast)
        .animation(Motion.standard, value: model.warnings.isEmpty)
        .onAppear {
            // `--show-settings` opens the settings window at launch (used for screenshots).
            if CommandLine.arguments.contains("--show-settings") { openSettings() }
        }
    }

    /// Clear of the footer, the note composer and the player bar.
    private var toastOffset: CGFloat {
        switch model.screen {
        case .live: return model.isRecording ? 104 : 56
        case .call: return model.reader.hasAudio ? 104 : 56
        case .home: return 56
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    if model.screen == .call {
                        LinkButton(title: "All calls", symbol: "chevron.left", font: TypeScale.calloutStrong) {
                            model.goHome()
                        }
                        .disabled(model.isBusy)
                        .help("Back to all calls (Esc or ⌘[)")
                    }
                    titleView
                    StatusLine()
                }
                Spacer(minLength: Space.s)
                HStack(spacing: Space.s) {
                    if model.screen == .live && model.isRecording {
                        PauseButton().transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    RecordButton(meter: model.meter)
                }
            }
            .readableColumn()
            .padding(.top, 6)
            .padding(.bottom, Space.l)
            .animation(Motion.standard, value: model.isRecording)

            if model.screen == .live {
                WaveRibbon(meter: model.meter, paused: model.paused)
                    .frame(height: 62)
                    .readableColumn()
                    .padding(.bottom, Space.l)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Hairline()
        }
    }

    @ViewBuilder
    private var titleView: some View {
        switch model.screen {
        case .home:
            TextField(
                "Name this call (optional)", text: $model.title,
                prompt: Text("Name this call (optional)").foregroundColor(Theme.inkFaint)
            )
            .textFieldStyle(.plain)
            .font(TypeScale.display)
            .foregroundStyle(Theme.ink)
            .disabled(model.isBusy)
            .onSubmit { model.toggle() }
        case .live:
            Text(model.title.isEmpty ? "Untitled call" : model.title)
                .font(TypeScale.display)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        case .call:
            EditableTitle()
        }
    }
}

/// The line under the title: what Earshot is doing right now.
private struct StatusLine: View {
    @EnvironmentObject private var model: AppModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            indicator.frame(width: 10)
            Text(text)
                .font(TypeScale.callout)
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var indicator: some View {
        if model.isBusy {
            ProgressView().controlSize(.mini)
        } else if model.screen == .live && model.paused {
            Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.inkSoft)
        } else if model.screen == .live {
            Dot(color: Theme.record, size: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
        } else if model.screen == .home, case .idle = model.phase {
            Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Theme.inkFaint)
        } else if case .failed = model.phase {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.caution)
        } else {
            EmptyView()
        }
    }

    private var text: String {
        switch model.phase {
        case .loading(let message), .finishing(let message), .failed(let message): return message
        case .starting: return "Starting…"
        case .recording:
            if model.paused { return "Paused — off the record until you resume (⇧⌘P)" }
            return "Live — you are Me, the Mac's audio is Them"
        case .idle:
            if model.screen == .call { return model.document?.detail ?? "" }
            return "Ready. Nothing you say leaves this Mac."
        }
    }
}

/// The one primary control: an ink capsule with a red dot that starts a recording, and turns
/// red with the running time while recording.
struct RecordButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meter: MeterModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        Button(action: model.toggle) {
            HStack(spacing: 9) {
                indicator.frame(width: 14, height: 14)
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, 18)
            .frame(minWidth: 116, minHeight: 40)
            .background(Capsule().fill(fill))
            .shadow(color: .black.opacity(disabled ? 0 : hovering ? 0.22 : 0.14), radius: hovering ? 9 : 6, y: 3)
            .background {
                if model.isRecording && !model.paused {
                    // Halo that breathes with the loudest input.
                    Capsule()
                        .stroke(Theme.record.opacity(0.35), lineWidth: 2)
                        .scaleEffect(x: 1 + 0.08 * CGFloat(meter.latest), y: 1 + 0.36 * CGFloat(meter.latest))
                        .animation(.easeOut(duration: 0.18), value: meter.latest)
                }
            }
            .opacity(disabled ? 0.55 : 1)
            .contentShape(Capsule())
            .contentShape(.focusEffect, Capsule())
            .animation(Motion.quick, value: hovering)
            .animation(Motion.standard, value: model.isRecording)
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .onHover { hovering = $0 }
        .keyboardShortcut("r", modifiers: .command)
        .help(model.isRecording ? "Stop and summarize (⌘R)" : "Start transcribing (⌘R)")
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")
    }

    private var disabled: Bool { model.isBusy || (model.phase != .idle && !model.isRecording) }

    private var fill: Color {
        let base = model.isRecording ? Theme.record : Theme.ink
        return base.opacity(hovering && !disabled ? 0.9 : 1)
    }

    @ViewBuilder
    private var indicator: some View {
        if model.isBusy {
            // The spinner draws for the opposite appearance so it shows on the ink fill.
            ProgressView().controlSize(.small).environment(\.colorScheme, colorScheme == .dark ? .light : .dark)
        } else if model.isRecording {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Theme.onInk).frame(width: 11, height: 11)
        } else {
            Circle().fill(Theme.record).frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Theme.onInk.opacity(0.35), lineWidth: 1))
        }
    }

    private var label: String {
        switch model.phase {
        // While paused the pause button, subtitle and waveform say so; this button still stops.
        case .recording: return model.paused ? "Stop" : TranscriptFormat.timestamp(model.elapsed)
        case .loading: return "Loading"
        case .starting: return "Starting"
        case .finishing: return "Finishing"
        case .idle, .failed: return "Record"
        }
    }
}

/// Two-lane rolling waveform: Me rises above the centre line, Them falls below it.
struct WaveRibbon: View {
    @ObservedObject var meter: MeterModel
    var paused = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading) {
                Eyebrow(text: "Me", color: Theme.tone(0))
                Spacer(minLength: 0)
                Eyebrow(text: "Them", color: Theme.tone(1))
            }
            .frame(width: 40, alignment: .leading)

            Canvas { context, size in
                let step: CGFloat = 4
                let barWidth: CGFloat = 2.4
                let middle = size.height / 2
                let reach = middle - 3
                let count = Int(size.width / step)
                let me = meter.me
                let them = meter.them
                let meColor = Theme.tone(0)
                let themColor = Theme.tone(1)

                context.fill(
                    Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)), with: .color(Theme.stroke))

                for index in 0..<count {
                    let x = size.width - CGFloat(index) * step - barWidth
                    // Older audio fades out toward the left edge.
                    let fade = 1 - 0.8 * Double(index) / Double(max(1, count))
                    let up = max(1.5, CGFloat(value(me, index)) * reach)
                    let down = max(1.5, CGFloat(value(them, index)) * reach)
                    context.fill(
                        Path(roundedRect: CGRect(x: x, y: middle - 1.5 - up, width: barWidth, height: up), cornerRadius: 1.2),
                        with: .color(meColor.opacity(fade)))
                    context.fill(
                        Path(roundedRect: CGRect(x: x, y: middle + 1.5, width: barWidth, height: down), cornerRadius: 1.2),
                        with: .color(themColor.opacity(fade)))
                }
            }
            .opacity(paused ? 0.25 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Theme.hairline))
        .overlay {
            if paused {
                Label("Paused — off the record", systemImage: "pause.circle.fill")
                    .labelStyle(TightLabelStyle())
                    .font(TypeScale.calloutStrong)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(Motion.standard, value: paused)
        .accessibilityElement()
        .accessibilityLabel(paused ? "Paused, off the record" : "Live input levels for Me and Them")
    }

    private func value(_ history: [Float], _ indexFromNewest: Int) -> Float {
        let index = history.count - 1 - indexFromNewest
        return index >= 0 ? history[index] : 0
    }
}

struct WarningsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning)
                        .font(TypeScale.callout)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Space.s)
            Button("Dismiss") { model.warnings = [] }.buttonStyle(.ghost(.small))
        }
        .readableColumn()
        .padding(.vertical, 10)
        .background(Theme.caution.opacity(0.10))
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Warning")
    }
}

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Space.s) {
            Text(footerText)
                .font(TypeScale.caption)
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(footerText)
            Spacer(minLength: Space.s)
            // Labels fold into icons when the window is narrow.
            ViewThatFits(in: .horizontal) {
                footerButtons(iconOnly: false)
                footerButtons(iconOnly: true)
            }
            .layoutPriority(1)
        }
        .readableColumn(gutter: Metrics.gutter - 6)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Hairline() }
    }

    private func footerButtons(iconOnly: Bool) -> some View {
        HStack(spacing: 2) {
            switch model.screen {
            case .home:
                SettingsLink { FooterLabel("Settings", "gearshape", iconOnly) }
                    .buttonStyle(.ghost(.small))
                    .help("Settings (⌘,)")
                Button { model.openCallsFolder() } label: { FooterLabel("Calls folder", "folder", iconOnly) }
                    .buttonStyle(.ghost(.small))
                    .help("Open the calls folder in Finder")
            case .live:
                Button { model.revealInFinder() } label: { FooterLabel("Show in Finder", "folder", iconOnly) }
                    .buttonStyle(.ghost(.small))
            case .call:
                Button { model.regenerateSummary() } label: { FooterLabel("Regenerate summary", "arrow.clockwise", iconOnly) }
                    .buttonStyle(.ghost(.small))
                    .disabled(model.phase != .idle || (model.document?.turns.isEmpty ?? true))
                    .help("Write the summary again from the transcript")
                Button { model.revealInFinder() } label: { FooterLabel("Show in Finder", "folder", iconOnly) }
                    .buttonStyle(.ghost(.small))
                TrashButton()
            }
        }
        .fixedSize()
    }
}

/// A footer button's label; just the symbol when space is short (VoiceOver still reads the title).
private struct FooterLabel: View {
    let title: String
    let symbol: String
    let iconOnly: Bool

    init(_ title: String, _ symbol: String, _ iconOnly: Bool) {
        self.title = title
        self.symbol = symbol
        self.iconOnly = iconOnly
    }

    var body: some View {
        if iconOnly {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(minWidth: 14)
        } else {
            Label(title, systemImage: symbol)
        }
    }
}

extension FooterView {
    fileprivate var footerText: String {
        switch model.screen {
        case .home: return "\(model.library.count) saved call\(model.library.count == 1 ? "" : "s")"
        case .live: return model.status
        case .call: return model.document.map { ($0.folder.path as NSString).abbreviatingWithTildeInPath } ?? ""
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.library.isEmpty {
            welcome
        } else {
            // The reader wraps the scroll view so ↑/↓ can bring the selected call into view.
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    OpenActionItemsSection()
                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionHeader(title: "Recent calls") {
                            HomeSearchField(text: $model.search, navigator: model.home)
                                .frame(maxWidth: 230)
                        }
                        let calls = model.visibleLibrary
                        RecentCallsList(navigator: model.home, calls: calls, proxy: proxy)
                        if calls.isEmpty {
                            VStack(spacing: 6) {
                                Text("No calls mention “\(model.search.trimmingCharacters(in: .whitespaces))”")
                                    .font(TypeScale.bodyStrong)
                                    .foregroundStyle(Theme.ink)
                                Text("Search looks at titles, summaries, transcripts, notes and speaker names.")
                                    .font(TypeScale.callout)
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Space.xl)
                        }
                    }
                }
                .readableColumn()
                .padding(.top, 20)
                .padding(.bottom, Space.xl)
                .background(OverlayScrollers())
            }
            }
        }
    }

    @ViewBuilder
    private var welcome: some View {
        if case .failed(let message) = model.phase {
            EmptyState(title: "Earshot could not start", message: message) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.caution)
            } actions: {
                Button("Try again") { Task { await model.loadModels() } }.buttonStyle(.secondary)
            }
        } else {
            EmptyState(
                title: "Join your call, then press Record",
                message: "Earshot writes down both sides as they speak and hands you a summary when you stop."
            ) {
                Glyph().padding(.bottom, Space.xs)
            } actions: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.l) { hints }
                    VStack(alignment: .leading, spacing: Space.s) { hints }
                }
                .padding(.top, Space.xs)
            }
        }
    }

    @ViewBuilder
    private var hints: some View {
        Hint(color: Theme.tone(0), title: "Me", text: "your microphone")
        Hint(color: Theme.tone(1), title: "Them", text: "the Mac's audio")
        Hint(color: Theme.inkFaint, title: "Private", text: "all on this Mac")
    }
}

struct Hint: View {
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Dot(color: color)
            Text(title).font(TypeScale.calloutStrong).foregroundStyle(Theme.ink)
            Text(text).font(TypeScale.callout).foregroundStyle(Theme.inkSoft)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// One saved call in a day group: title and time, then the TL;DR.
struct CallRow: View {
    let call: SavedCall
    let open: () -> Void
    let trash: () -> Void
    /// Highlighted with ↑/↓ on the home screen.
    var selected = false
    /// The next ⌘⌫ moves this call to the Trash.
    var armed = false
    @State private var hovering = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM jj:mm")
        return formatter
    }()

    /// The day header already says which day for the past week; older calls show the date too.
    private var when: String {
        let recent = Date().timeIntervalSince(call.date) < 6 * 24 * 3600
        return (recent ? Self.time : Self.dayAndTime).string(from: call.date)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(call.title)
                        .font(TypeScale.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: Space.s)
                    if armed {
                        Label("Move to Trash? ⌘⌫", systemImage: "trash")
                            .labelStyle(TightLabelStyle(spacing: 4))
                            .font(TypeScale.captionStrong)
                            .foregroundStyle(Theme.record)
                            .fixedSize()
                    } else {
                        HStack(spacing: 5) {
                            Text(when)
                            if let duration = call.duration {
                                Text("·")
                                Text(duration)
                            }
                        }
                        .font(TypeScale.stamp)
                        .foregroundStyle(Theme.inkFaint)
                        .fixedSize()
                    }
                }
                if let overview = call.overview {
                    Text(inline(overview))
                        .font(TypeScale.readingCompact)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("No summary")
                        .font(TypeScale.callout)
                        .italic()
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge, lineWidth: 1.5))
            .padding(4)
            .contentShape(Rectangle())
            .contentShape(.focusEffect, shape)
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: selected)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityHint(armed ? "Press Command-Delete again to move it to the Trash" : "Opens the call")
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([call.folder]) }
            Divider()
            Button("Move to Trash", role: .destructive) { trash() }
        }
    }

    private var fill: Color {
        if armed { return Theme.record.opacity(0.08) }
        if selected { return Theme.washStrong }
        return hovering ? Theme.wash : .clear
    }

    private var edge: Color {
        if armed { return Theme.record.opacity(0.6) }
        return selected ? Theme.focus : .clear
    }
}

// MARK: - Live call

struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var follow = true
    private let bottom = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isRecording { NoteComposer().transition(.opacity.combined(with: .move(edge: .bottom))) }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.liveTurns.isEmpty && model.liveMarkers.isEmpty && model.partials.values.allSatisfy({ $0.isEmpty }) {
            listening
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(TranscriptRow.merge(turns: model.liveTurns, markers: model.liveMarkers)) { row in
                            TranscriptRowView(row: row).transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        ForEach(Channel.allCases, id: \.self) { channel in
                            if let text = model.partials[channel], !text.isEmpty {
                                TurnView(
                                    turn: DisplayTurn(
                                        id: "live-\(channel.rawValue)", label: channel == .me ? "Me" : "Them", time: "",
                                        text: text, tone: channel == .me ? 0 : 1),
                                    live: true)
                            }
                        }
                        Color.clear.frame(height: 1).id(bottom)
                    }
                    .readableColumn(gutter: Metrics.gutter - 8)
                    .padding(.top, Space.l)
                    // Room for the floating "Following" button under the newest line.
                    .padding(.bottom, 52)
                    .animation(Motion.standard, value: model.liveTurns.count + model.liveMarkers.count)
                    .background(OverlayScrollers())
                }
                .onChange(of: model.liveTurns) { _, _ in scroll(proxy) }
                .onChange(of: model.liveMarkers) { _, _ in scroll(proxy) }
                .onChange(of: model.partials) { _, _ in scroll(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        follow.toggle()
                        if follow { withAnimation { proxy.scrollTo(bottom, anchor: .bottom) } }
                    } label: {
                        if follow {
                            Label("Following", systemImage: "arrow.down.to.line")
                        } else {
                            Label("Jump to live", systemImage: "arrow.down")
                        }
                    }
                    .buttonStyle(.secondary(.small))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .help(follow ? "Click to stop following the live transcript" : "Scroll to the newest line and follow it")
                    .padding(14)
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard follow else { return }
        proxy.scrollTo(bottom, anchor: .bottom)
    }

    private var listening: some View {
        EmptyState(
            title: model.paused ? "Paused" : "Listening…",
            message: model.paused
                ? "Off the record: nothing is transcribed or saved until you resume (⇧⌘P)."
                : model.heardSystemAudio
                ? "Words appear here about half a second after they are spoken."
                : "Nothing is playing on this Mac yet. If the other side is talking and the Them lane stays flat, allow Earshot under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only."
        ) {
            if model.paused {
                Image(systemName: "pause.circle").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.inkFaint)
            } else {
                ListeningMark()
            }
        } actions: {
            EmptyView()
        }
    }
}

/// Three dots that breathe while waiting for the first words.
private struct ListeningMark: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Dot(color: index == 1 ? Theme.tone(1) : Theme.tone(0), size: 7)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.8).repeatForever().delay(Double(index) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityHidden(true)
    }
}

/// One speaker's stretch of talk: a rule in the speaker's colour, name and time, serif text.
struct TurnView: View {
    let turn: DisplayTurn
    var live = false
    /// Find highlights, playback and naming for a saved call's turn.
    var reading: TurnReading?
    @State private var pulse = false
    @State private var hovering = false

    var body: some View {
        let tone = Theme.tone(turn.tone)
        let playing = reading?.playing ?? false
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Space.s) {
                if let rename = reading?.rename {
                    SpeakerTag(turn: turn, color: tone, editing: rename)
                } else {
                    Eyebrow(text: turn.label, color: tone)
                }
                if live {
                    HStack(spacing: 4) {
                        Dot(color: tone, size: 5)
                            .opacity(pulse ? 0.25 : 1)
                            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                            .onAppear { pulse = true }
                        Text("live").font(TypeScale.stamp).foregroundStyle(Theme.inkFaint)
                    }
                } else if let play = reading?.play {
                    Button(action: play) {
                        HStack(spacing: 4) {
                            Text(turn.time).font(TypeScale.stamp)
                            Image(systemName: playing ? "speaker.wave.2.fill" : "play.fill")
                                .font(.system(size: 7.5, weight: .bold))
                                .opacity(hovering || playing ? 1 : 0)
                        }
                        .foregroundStyle(hovering || playing ? Theme.ink : Theme.inkFaint)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Play from here")
                    .accessibilityLabel("Play from \(turn.time)")
                } else {
                    Text(turn.time).font(TypeScale.stamp).foregroundStyle(Theme.inkFaint)
                }
                Spacer(minLength: 0)
            }
            Text(reading?.text ?? AttributedString(turn.text))
                .font(TypeScale.reading)
                .lineSpacing(TypeScale.readingLeading)
                .foregroundStyle(live ? Theme.inkSoft : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.l - 2, style: .continuous).fill(background(tone, playing: playing))
        )
        .overlay(alignment: .leading) {
            Capsule().fill(tone.opacity(live ? 0.6 : 1)).frame(width: 2.5).padding(.vertical, 12).padding(.leading, 6)
        }
        .onHover { hovering = reading != nil && $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.standard, value: playing)
    }

    private func background(_ tone: Color, playing: Bool) -> Color {
        if live { return tone.opacity(0.07) }
        if playing { return tone.opacity(0.10) }
        return hovering ? Theme.wash : .clear
    }
}

// MARK: - Finished call

struct CallView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var reader: CallReader

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Space.s) {
                ZStack {
                    PillTabs(selection: $model.tab, options: AppModel.Tab.allCases.map { ($0, $0.rawValue) })
                    HStack {
                        Spacer()
                        ExportButton()
                    }
                }
                if reader.findOpen { FindBar().transition(.opacity.combined(with: .move(edge: .top))) }
            }
            .readableColumn()
            .padding(.top, 14)
            .padding(.bottom, 6)
            Group {
                switch model.tab {
                case .transcript: transcript
                case .summary: SummaryView()
                }
            }
            .frame(maxHeight: .infinity)
            if reader.hasAudio { PlayerBar(player: reader.player, follow: $reader.follow) }
        }
        .animation(Motion.standard, value: reader.findOpen)
        // Closing the window leaves the call too.
        .onDisappear { reader.player.pause() }
    }

    @ViewBuilder
    private var transcript: some View {
        let turns = model.document?.turns ?? []
        let markers = model.document?.markers ?? []
        if turns.isEmpty && markers.isEmpty {
            EmptyState(
                title: "No speech was detected",
                message: "Check that the call's audio plays through this Mac and that the microphone is the one you expect.")
        } else {
            CallTranscript()
        }
    }
}
