import EarshotCore
import SwiftUI

/// The single window: header (title + record control), then home, live call or finished call.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            if !model.warnings.isEmpty { WarningsView() }
            Group {
                switch model.screen {
                case .home: HomeView()
                case .live: LiveView()
                case .call: CallView().environmentObject(model.reader)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FooterView()
        }
        .frame(minWidth: 480, minHeight: 520)
        .background(Theme.background.ignoresSafeArea())
        .background(WindowChrome())
        .overlay(alignment: .top) {
            // Wordmark in the (hidden) title bar.
            Text("EARSHOT")
                .font(.ui(10.5, .bold))
                .tracking(2.4)
                .foregroundStyle(Theme.inkFaint)
                .frame(height: 28)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 54)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .tint(Theme.me)
        .animation(.snappy(duration: 0.28), value: model.screen)
        .animation(.snappy(duration: 0.22), value: model.toast)
        .onAppear {
            // `--show-settings` opens the settings window at launch (used for screenshots).
            if CommandLine.arguments.contains("--show-settings") { openSettings() }
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if model.screen == .call {
                        Button(action: model.goHome) {
                            Label("All calls", systemImage: "chevron.left")
                                .font(.ui(11.5, .semibold))
                                .foregroundStyle(Theme.me)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                    }
                    titleView
                    subtitle
                }
                Spacer(minLength: 8)
                RecordButton(meter: model.meter)
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 16)

            if model.screen == .live {
                WaveRibbon(meter: model.meter)
                    .frame(height: 58)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        switch model.screen {
        case .home:
            TextField("Name this call (optional)", text: $model.title)
                .textFieldStyle(.plain)
                .font(.ui(22, .semibold))
                .foregroundStyle(Theme.ink)
                .disabled(model.isBusy)
                .onSubmit { model.toggle() }
        case .live:
            Text(model.title.isEmpty ? "Untitled call" : model.title)
                .font(.ui(22, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        case .call:
            EditableTitle()
        }
    }

    private var subtitle: some View {
        HStack(spacing: 6) {
            if model.isBusy {
                ProgressView().controlSize(.mini)
            } else if model.screen == .live {
                Circle().fill(Theme.record).frame(width: 6, height: 6)
            }
            Text(subtitleText)
                .font(.ui(12.5))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var subtitleText: String {
        switch model.phase {
        case .loading(let message), .finishing(let message), .failed(let message): return message
        case .starting: return "Starting…"
        case .recording: return "Live — you are Me, the Mac's audio is Them"
        case .idle:
            if model.screen == .call { return model.document?.detail ?? "" }
            return "Ready. Nothing you say leaves this Mac."
        }
    }
}

/// The one primary control: a glowing capsule that starts and stops a recording.
struct RecordButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meter: MeterModel
    @State private var hovering = false

    var body: some View {
        Button(action: model.toggle) {
            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else if model.isRecording {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white).frame(width: 12, height: 12)
                } else {
                    Circle().fill(.white).frame(width: 12, height: 12)
                }
                Text(label)
                    .font(.ui(14.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .frame(minWidth: 124, minHeight: 42)
            .background(Capsule().fill(model.isRecording ? Theme.recordGradient : Theme.accentGradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: glow.opacity(disabled ? 0 : 0.42), radius: hovering ? 14 : 10, y: 4)
            .background {
                if model.isRecording {
                    // Halo that breathes with the loudest input.
                    Capsule()
                        .stroke(Theme.record.opacity(0.35), lineWidth: 2)
                        .scaleEffect(x: 1 + 0.10 * CGFloat(meter.latest), y: 1 + 0.42 * CGFloat(meter.latest))
                        .animation(.easeOut(duration: 0.18), value: meter.latest)
                }
            }
            .saturation(disabled ? 0.35 : 1)
            .opacity(disabled ? 0.6 : 1)
            .scaleEffect(hovering && !disabled ? 1.03 : 1)
            .animation(.snappy(duration: 0.18), value: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .keyboardShortcut("r", modifiers: .command)
        .help(model.isRecording ? "Stop and summarize (⌘R)" : "Start transcribing (⌘R)")
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")
    }

    private var disabled: Bool { model.isBusy || (model.phase != .idle && !model.isRecording) }
    private var glow: Color { model.isRecording ? Color(hex: 0xE5484D) : Color(hex: 0x0EA5E9) }

    private var label: String {
        switch model.phase {
        case .recording: return TranscriptFormat.timestamp(model.elapsed)
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

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading) {
                Eyebrow(text: "Me", color: Theme.tone(0))
                Spacer(minLength: 0)
                Eyebrow(text: "Them", color: Theme.tone(1))
            }
            .frame(width: 38, alignment: .leading)

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
                    Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)), with: .color(Theme.hairline))

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well))
        .accessibilityElement()
        .accessibilityLabel("Live input levels for Me and Them")
    }

    private func value(_ history: [Float], _ indexFromNewest: Int) -> Float {
        let index = history.count - 1 - indexFromNewest
        return index >= 0 ? history[index] : 0
    }
}

struct WarningsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning)
                        .font(.ui(12.5))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Dismiss") { model.warnings = [] }.buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Theme.caution.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(footerText)
                .font(.ui(11.5))
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            footerButtons.fixedSize().layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var footerButtons: some View {
        HStack(spacing: 8) {
            switch model.screen {
            case .home:
                SettingsLink { Label("Settings", systemImage: "slider.horizontal.3") }
                    .buttonStyle(GhostButtonStyle())
                Button { model.openCallsFolder() } label: { Label("Calls folder", systemImage: "folder") }
                    .buttonStyle(GhostButtonStyle())
            case .live:
                Button { model.revealInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(GhostButtonStyle())
            case .call:
                Button { model.regenerateSummary() } label: { Label("Regenerate summary", systemImage: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(model.phase != .idle || (model.document?.turns.isEmpty ?? true))
                Button { model.revealInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(GhostButtonStyle())
                TrashButton()
            }
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Eyebrow(text: "Recent calls").padding(.leading, 2)
                        Spacer(minLength: 8)
                        SearchField(text: $model.search)
                    }
                    .padding(.bottom, 2)
                    let calls = model.visibleLibrary
                    ForEach(calls) { call in
                        CallRow(call: call, open: { model.open(call) }, trash: { model.trash(call.folder) })
                    }
                    if calls.isEmpty {
                        Text("No calls mention “\(model.search.trimmingCharacters(in: .whitespaces))”.")
                            .font(.reading(14))
                            .foregroundStyle(Theme.inkSoft)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .background(OverlayScrollers())
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Glyph()
            VStack(spacing: 6) {
                if case .failed(let message) = model.phase {
                    Text("Earshot could not start").font(.ui(19, .semibold)).foregroundStyle(Theme.ink)
                    Text(message).font(.ui(13)).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center)
                    Button("Try again") { Task { await model.loadModels() } }.buttonStyle(GhostButtonStyle()).padding(.top, 6)
                } else {
                    Text("Join your call, then press Record").font(.ui(19, .semibold)).foregroundStyle(Theme.ink)
                    Text("Earshot writes down both sides as they speak and hands you a summary when you stop.")
                        .font(.reading(14.5))
                        .foregroundStyle(Theme.inkSoft)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
            }
            HStack(spacing: 18) {
                Hint(color: Theme.tone(0), title: "Me", text: "your microphone")
                Hint(color: Theme.tone(1), title: "Them", text: "the Mac's audio")
                Hint(color: Theme.inkFaint, title: "Private", text: "all on this Mac")
            }
            .padding(.top, 4)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: 400)
        .padding(28)
    }
}

/// The two-lane waveform as a still mark.
struct Glyph: View {
    private let heights: [CGFloat] = [0.3, 0.55, 0.9, 0.65, 1.0, 0.45, 0.75, 0.35, 0.6, 0.25]

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                VStack(spacing: 3) {
                    Capsule().fill(Theme.tone(0)).frame(width: 5, height: 26 * height)
                    Capsule().fill(Theme.tone(1)).frame(width: 5, height: 26 * heights[heights.count - 1 - index])
                }
                .frame(height: 62)
            }
        }
        .accessibilityHidden(true)
    }
}

struct Hint: View {
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.ui(12, .semibold)).foregroundStyle(Theme.ink)
            Text(text).font(.ui(12)).foregroundStyle(Theme.inkSoft)
        }
        .fixedSize()
    }
}

struct CallRow: View {
    let call: SavedCall
    let open: () -> Void
    let trash: () -> Void
    @State private var hovering = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(call.title)
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let overview = call.overview {
                        Text(overview)
                            .font(.reading(13.5))
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(2)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 6) {
                        Text(Self.formatter.string(from: call.date))
                        if let duration = call.duration {
                            Text("·")
                            Text(duration)
                        }
                    }
                    .font(.stamp(10.5))
                    .foregroundStyle(Theme.inkFaint)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.me : Theme.inkFaint)
                    .padding(.top, 3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Theme.me.opacity(0.45) : Theme.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([call.folder]) }
            Divider()
            Button("Move to Trash", role: .destructive) { trash() }
        }
    }
}

// MARK: - Live call

struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var follow = true
    private let bottom = "bottom"

    var body: some View {
        if model.liveTurns.isEmpty && model.partials.values.allSatisfy({ $0.isEmpty }) {
            listening
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.liveTurns) { turn in
                            TurnView(turn: turn).transition(.opacity.combined(with: .move(edge: .bottom)))
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
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .animation(.snappy(duration: 0.25), value: model.liveTurns.count)
                    .background(OverlayScrollers())
                }
                .onChange(of: model.liveTurns) { _, _ in scroll(proxy) }
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
                    .buttonStyle(GhostButtonStyle())
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
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
        VStack(spacing: 10) {
            Text("Listening…").font(.ui(19, .semibold)).foregroundStyle(Theme.ink)
            Text(
                model.heardSystemAudio
                    ? "Words appear here about half a second after they are spoken."
                    : "Nothing is playing on this Mac yet. If the other side is talking and the Them lane stays flat, allow Earshot under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only."
            )
            .font(.reading(14))
            .foregroundStyle(Theme.inkSoft)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
        }
        .frame(maxWidth: 400)
        .padding(28)
    }
}

/// One speaker's stretch of talk: coloured rule, speaker tag, timestamp, serif text.
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
            HStack(spacing: 7) {
                if let rename = reading?.rename {
                    SpeakerTag(turn: turn, color: tone, editing: rename)
                } else {
                    Eyebrow(text: turn.label, color: tone)
                }
                if live {
                    Circle()
                        .fill(tone)
                        .frame(width: 5, height: 5)
                        .opacity(pulse ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                }
                Spacer(minLength: 8)
                if let play = reading?.play {
                    Button(action: play) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                                .opacity(hovering || playing ? 1 : 0)
                            Text(turn.time).font(.stamp(10.5))
                        }
                        .foregroundStyle(hovering || playing ? Theme.me : Theme.inkFaint)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play from here")
                } else {
                    Text(live ? "live" : turn.time).font(.stamp(10.5)).foregroundStyle(Theme.inkFaint)
                }
            }
            Text(reading?.text ?? AttributedString(turn.text))
                .font(.reading(15.5))
                .lineSpacing(4.5)
                .foregroundStyle(live ? Theme.inkSoft : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(live ? tone.opacity(0.08) : playing ? tone.opacity(0.06) : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(live ? tone.opacity(0.28) : playing ? tone.opacity(0.35) : Theme.hairline)
        )
        .overlay(alignment: .leading) {
            Capsule().fill(tone).frame(width: 3).padding(.vertical, 11).padding(.leading, 6)
        }
        .onHover { hovering = reading != nil && $0 }
        .animation(.easeOut(duration: 0.2), value: playing)
    }
}

// MARK: - Finished call

struct CallView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var reader: CallReader

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PillTabs(selection: $model.tab)
                HStack {
                    Spacer()
                    ExportButton()
                }
                .padding(.horizontal, 24)
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
            if reader.findOpen { FindBar().transition(.opacity.combined(with: .move(edge: .top))) }
            switch model.tab {
            case .transcript: transcript
            case .summary: SummaryView()
            }
            if reader.hasAudio { PlayerBar(player: reader.player, follow: $reader.follow) }
        }
        .animation(.snappy(duration: 0.2), value: reader.findOpen)
        // Closing the window leaves the call too.
        .onDisappear { reader.player.pause() }
    }

    @ViewBuilder
    private var transcript: some View {
        let turns = model.document?.turns ?? []
        if turns.isEmpty {
            VStack(spacing: 8) {
                Text("No speech was detected").font(.ui(17, .semibold)).foregroundStyle(Theme.ink)
                Text("Check that the call's audio plays through this Mac and that the microphone is the one you expect.")
                    .font(.reading(14)).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 380, maxHeight: .infinity)
            .padding(28)
        } else {
            CallTranscript()
        }
    }
}

/// Sliding two-way switch.
struct PillTabs: View {
    @Binding var selection: AppModel.Tab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.ui(12.5, .semibold))
                        .foregroundStyle(selection == tab ? Theme.background : Theme.inkSoft)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background {
                            if selection == tab {
                                Capsule().fill(Theme.ink).matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.well))
    }
}
