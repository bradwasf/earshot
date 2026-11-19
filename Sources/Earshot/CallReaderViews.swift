import AppKit
import EarshotCore
import SwiftUI

// MARK: - Transcript of a saved call

/// The finished call's turns, with find highlights, playback and speaker naming.
struct CallTranscript: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var reader: CallReader

    var body: some View {
        let turns = model.document?.turns ?? []
        let canPlay = reader.hasAudio
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let talk = model.document?.talk, !talk.isEmpty {
                        TalkTimeStrip(shares: talk, duration: model.document?.durationText)
                            .padding(.horizontal, 8)
                            .padding(.bottom, Space.s)
                    }
                    if turns.isEmpty {
                        Text("No speech was detected; only your notes were saved.")
                            .font(TypeScale.callout).foregroundStyle(Theme.inkSoft).padding(.horizontal, 8).padding(.bottom, 4)
                    }
                    ForEach(TranscriptRow.merge(turns: turns, markers: model.document?.markers ?? [])) { row in
                        switch row {
                        case .marker(let marker):
                            MarkerView(marker: marker)
                        case .turn(let turn):
                            TurnView(
                                turn: turn,
                                reading: TurnReading(
                                    text: reader.findOpen ? reader.highlight(turn.text, block: turn.id) : nil,
                                    playing: canPlay && reader.playingTurn == turn.id,
                                    play: canPlay && turn.start != nil ? { reader.play(from: turn) } : nil,
                                    rename: model.canEditSpeakers && turn.originalLabel != nil ? renaming(turn) : nil)
                            )
                            .id(turn.id)
                            .contextMenu { menu(for: turn, canPlay: canPlay) }
                        }
                    }
                }
                .readableColumn(gutter: Metrics.gutter - 8)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xl)
                .background(OverlayScrollers())
            }
            .onChange(of: reader.scrollRequest) { _, request in
                guard let request, turns.contains(where: { $0.id == request.block }) else { return }
                withAnimation(Motion.standard) { proxy.scrollTo(request.block, anchor: .center) }
            }
        }
    }

    private func renaming(_ turn: DisplayTurn) -> Binding<Bool> {
        Binding(
            get: { reader.renamingTurn == turn.id },
            set: { open in
                if open {
                    reader.renamingTurn = turn.id
                } else if reader.renamingTurn == turn.id {
                    reader.renamingTurn = nil
                }
            })
    }

    @ViewBuilder
    private func menu(for turn: DisplayTurn, canPlay: Bool) -> some View {
        Button("Copy Text") { model.copyTurn(turn, withSpeaker: false) }
        Button("Copy with Time and Speaker") { model.copyTurn(turn, withSpeaker: true) }
        if canPlay, turn.start != nil {
            Divider()
            Button("Play from Here") { reader.play(from: turn) }
        }
        if turn.originalLabel != nil {
            Divider()
            Button("Rename \(turn.label)…") { reader.renamingTurn = turn.id }
                .disabled(!model.canEditSpeakers)
        }
    }
}

/// What a saved call's turn adds to `TurnView`.
struct TurnReading {
    /// The text with find matches marked (nil: plain text).
    var text: AttributedString?
    /// The recording is at this turn.
    var playing = false
    /// Clicking the timestamp plays from here (nil without a recording).
    var play: (() -> Void)?
    /// Shows the speaker-name editor (nil while names cannot be changed).
    var rename: Binding<Bool>?
}

/// The speaker tag of a saved turn: click it to name the speaker.
struct SpeakerTag: View {
    let turn: DisplayTurn
    let color: Color
    @Binding var editing: Bool
    @State private var hovering = false

    var body: some View {
        Button { editing = true } label: {
            Eyebrow(text: turn.label, color: color)
                .underline(hovering, color: color.opacity(0.5))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(hovering ? color.opacity(0.12) : .clear))
            .padding(.horizontal, -5)
            .contentShape(Rectangle())
            .animation(Motion.quick, value: hovering)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help("Name this speaker")
        .accessibilityLabel("\(turn.label), name this speaker")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            SpeakerNameEditor(turn: turn, color: color) { editing = false }
        }
    }
}

/// The popover that names a speaker for this call.
struct SpeakerNameEditor: View {
    @EnvironmentObject private var model: AppModel
    let turn: DisplayTurn
    let color: Color
    let close: () -> Void
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var original: String { turn.originalLabel ?? turn.label }
    private var isNamed: Bool { turn.label != original }
    private var turnCount: Int { model.document?.turns.filter { $0.originalLabel == original }.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: 6) {
                Dot(color: color)
                Eyebrow(text: original == "Me" ? "Name yourself" : "Name \(original)", color: color)
            }
            TextField(original == "Me" ? "Your name" : "Their name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .fieldChrome(focused: focused, capsule: false)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: draft) { _, _ in error = nil }
            Text(
                error
                    ?? "Shown on all \(turnCount) turn\(turnCount == 1 ? "" : "s") and written into transcript.md and summary.md."
            )
            .font(TypeScale.caption)
            .foregroundStyle(error == nil ? Theme.inkSoft : Theme.record)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if isNamed {
                    Button("Use “\(original)”") { commit(nil) }.buttonStyle(.ghost(.small))
                }
                Spacer(minLength: 0)
                Button("Cancel", action: close).buttonStyle(.secondary(.small))
                Button("Save", action: save)
                    .buttonStyle(.primary(.small))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.l)
        .frame(width: 290)
        .background(Theme.surface)
        .presentationBackground(Theme.surface)
        .onAppear {
            draft = isNamed ? turn.label : ""
            DispatchQueue.main.async { focused = true }
        }
    }

    private func save() { commit(draft) }

    private func commit(_ name: String?) {
        if let message = model.renameSpeaker(original, to: name) {
            error = message
        } else {
            close()
        }
    }
}

// MARK: - Find bar

/// ⌘F in a finished call: highlights matches in the visible tab and steps through them.
struct FindBar: View {
    @EnvironmentObject private var reader: CallReader
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            TextField(
                model.tab == .summary ? "Find in summary" : "Find in transcript", text: $reader.query,
                prompt: Text(model.tab == .summary ? "Find in summary" : "Find in transcript").foregroundColor(Theme.inkFaint)
            )
            .textFieldStyle(.plain)
            .font(TypeScale.body)
            .foregroundStyle(Theme.ink)
            .focused($focused)
            .onKeyPress(.return, phases: .down) { press in
                press.modifiers.contains(.shift) ? reader.previous() : reader.next()
                return .handled
            }
            .onExitCommand { reader.closeFind() }
            Text(reader.countText)
                .font(TypeScale.stamp)
                .foregroundStyle(reader.hits.isEmpty ? Theme.inkFaint : Theme.inkSoft)
                .fixedSize()
                .accessibilityLabel(reader.countText.isEmpty ? "" : "Matches: \(reader.countText)")
            HStack(spacing: 0) {
                IconButton(symbol: "chevron.up", label: "Previous match (⇧⌘G)", size: 22) { reader.previous() }
                IconButton(symbol: "chevron.down", label: "Next match (⌘G)", size: 22) { reader.next() }
            }
            .disabled(reader.hits.isEmpty)
            Hairline(vertical: true).frame(height: 14)
            IconButton(symbol: "xmark", label: "Close (Esc)", size: 22) { reader.closeFind() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 30)
        .fieldChrome(focused: focused)
        .onAppear { focused = true }
        .onChange(of: reader.focusRequest) { _, _ in focused = true }
    }
}

// MARK: - Player

/// Play the call's recording: play/pause, ±15 s, scrubber, speed, follow along.
struct PlayerBar: View {
    @ObservedObject var player: CallPlayer
    @Binding var follow: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: 2) {
                IconButton(symbol: "gobackward.15", label: "Back 15 seconds") { player.skip(-15) }
                IconButton(
                    symbol: player.isPlaying ? "pause.fill" : "play.fill",
                    label: player.isPlaying ? "Pause" : "Play",
                    help: player.isPlaying ? "Pause (Space)" : "Play the recording (Space)",
                    size: 32, style: .primary, action: player.toggle)
                IconButton(symbol: "goforward.15", label: "Forward 15 seconds") { player.skip(15) }
            }
            Text(TranscriptFormat.timestamp(player.time, alwaysHours: player.duration >= 3600))
                .font(TypeScale.stamp).foregroundStyle(Theme.ink)
                .fixedSize()
            Scrubber(time: player.time, duration: player.duration) { player.seek(to: $0) }
            Text(TranscriptFormat.timestamp(player.duration, alwaysHours: player.duration >= 3600))
                .font(TypeScale.stamp).foregroundStyle(Theme.inkFaint)
                .fixedSize()
            Button(action: player.cycleRate) {
                Text(rateText).font(TypeScale.stamp).frame(minWidth: 24)
            }
            .buttonStyle(.ghost(.small))
            .help("Playback speed")
            .accessibilityLabel("Playback speed \(rateText)")
            IconButton(
                symbol: "text.line.first.and.arrowtriangle.forward",
                label: follow ? "Stop following playback" : "Follow playback",
                help: follow ? "Following the recording in the transcript (click to stop)" : "Follow the recording in the transcript",
                selected: follow
            ) { follow.toggle() }
        }
        .readableColumn(gutter: Metrics.gutter - 8)
        .padding(.vertical, 7)
        .background(Theme.surface.opacity(0.6))
        .overlay(alignment: .top) { Hairline() }
    }

    private var rateText: String {
        player.rate == 1 ? "1×" : player.rate == 2 ? "2×" : String(format: "%.1f×", player.rate)
    }
}

/// A thin track with a knob; click or drag to seek.
struct Scrubber: View {
    let time: Double
    let duration: Double
    let seek: (Double) -> Void
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let fraction = duration > 0 ? min(1, max(0, (dragging ?? time) / duration)) : 0
            let width = geometry.size.width
            let active = hovering || dragging != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.washStrong).frame(height: active ? 5 : 4)
                Capsule().fill(Theme.ink).frame(width: max(4, width * fraction), height: active ? 5 : 4)
                Circle()
                    .fill(Theme.ink)
                    .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                    .frame(width: 13, height: 13)
                    .offset(x: width * fraction - 6.5)
                    .opacity(active ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(Motion.quick, value: active)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragging = position(value.location.x, width) }
                    .onEnded { value in
                        seek(position(value.location.x, width))
                        dragging = nil
                    })
        }
        .frame(height: 22)
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(TranscriptFormat.timestamp(time))
        .accessibilityAdjustableAction { direction in
            seek(time + (direction == .increment ? 15 : -15))
        }
    }

    private func position(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * duration
    }
}

// MARK: - Talk time

/// Each speaker's share of the talking, as a thin stacked bar in speaker colours.
struct TalkTimeStrip: View {
    let shares: [TalkShare]
    let duration: String?

    var body: some View {
        let percents = TalkTime.percentages(shares)
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Talk time", count: nil) {
                if let duration {
                    Label(duration, systemImage: "clock")
                        .labelStyle(TightLabelStyle(spacing: 4))
                        .font(TypeScale.stamp)
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(shares) { share in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(share))
                            .frame(width: max(3, (geometry.size.width - CGFloat(shares.count - 1) * 2) * share.fraction))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            FlowingLegend(spacing: 14) {
                ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                    HStack(spacing: 5) {
                        Dot(color: color(share), size: 6)
                        Text(share.name).font(TypeScale.captionStrong).foregroundStyle(Theme.ink).lineLimit(1)
                        Text("\(percents[index])%").font(TypeScale.stamp).foregroundStyle(Theme.inkSoft)
                    }
                    .help("\(share.name): about \(TranscriptFormat.timestamp(share.seconds)) of talk")
                }
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Talk time: " + zip(shares, percents).map { "\($0.name) \($1) percent" }.joined(separator: ", "))
    }

    private func color(_ share: TalkShare) -> Color {
        Theme.tone(Theme.tone(channel: share.channel, speaker: share.speaker))
    }
}

/// Lays its children out in rows, wrapping when the window is narrow.
struct FlowingLegend: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * 4
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + 4
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

// MARK: - Menu commands

/// Edit › Find in Call (⌘F), Find Next (⌘G) and Find Previous (⇧⌘G) for a finished call.
struct CallCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var reader: CallReader

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in Call…") {
                if model.screen == .call { reader.showFind() }
            }
            .keyboardShortcut("f")
            .disabled(model.screen != .call)
            Button("Find Next") { reader.next() }
                .keyboardShortcut("g")
                .disabled(model.screen != .call || reader.hits.isEmpty)
            Button("Find Previous") { reader.previous() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.screen != .call || reader.hits.isEmpty)
        }
    }
}
