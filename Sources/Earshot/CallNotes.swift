import EarshotCore
import SwiftUI

// Notes, marks and "off the record" pauses: what the user adds to a call's timeline while recording.

/// A note, mark or pause as drawn in the transcript (live or saved).
struct DisplayMarker: Identifiable, Equatable {
    let id: String
    let kind: CallMarker.Kind
    /// "12:03", or "03:12 – 04:40" for a finished pause.
    let time: String
    let text: String
    /// A pause that is still going on.
    let isOpen: Bool
    /// How many turns come before it in the transcript.
    let afterTurns: Int

    init(_ marker: CallMarker, id: String, afterTurns: Int) {
        self.id = id
        self.kind = marker.kind
        self.time = TranscriptFormat.markerTime(marker)
        self.text = marker.text
        self.isOpen = marker.kind == .pause && marker.end == nil
        self.afterTurns = afterTurns
    }
}

/// One row of a transcript: a speaker turn, or a note, mark or pause between turns.
enum TranscriptRow: Identifiable, Equatable {
    case turn(DisplayTurn)
    case marker(DisplayMarker)

    var id: String {
        switch self {
        case .turn(let turn): return turn.id
        case .marker(let marker): return "marker-" + marker.id
        }
    }

    /// Turns with the markers placed after the number of turns each one follows.
    static func merge(turns: [DisplayTurn], markers: [DisplayMarker]) -> [TranscriptRow] {
        guard !markers.isEmpty else { return turns.map { .turn($0) } }
        var rows: [TranscriptRow] = []
        var next = 0
        let ordered = markers.sorted { $0.afterTurns < $1.afterTurns }
        for (index, turn) in turns.enumerated() {
            while next < ordered.count, ordered[next].afterTurns <= index {
                rows.append(.marker(ordered[next]))
                next += 1
            }
            rows.append(.turn(turn))
        }
        rows += ordered[next...].map { .marker($0) }
        return rows
    }

    /// The row as one line of copied text ("[00:12] Them 2: …", "[12:03] Note: …").
    var plainText: String {
        switch self {
        case .turn(let turn): return "[\(turn.time)] \(turn.label): \(turn.text)"
        case .marker(let marker):
            switch marker.kind {
            case .note: return "[\(marker.time)] Note: \(marker.text)"
            case .mark: return "[\(marker.time)] Marked"
            case .pause: return "[\(marker.time)] Paused (off the record)"
            }
        }
    }
}

struct TranscriptRowView: View {
    let row: TranscriptRow

    var body: some View {
        switch row {
        case .turn(let turn): TurnView(turn: turn)
        case .marker(let marker): MarkerView(marker: marker)
        }
    }
}

/// A note reads as the user's own aside (sans-serif in a margin-note well, no speaker rule);
/// marks and pauses are slim dividers across the transcript.
struct MarkerView: View {
    let marker: DisplayMarker

    var body: some View {
        switch marker.kind {
        case .note: note
        case .mark:
            divider(symbol: "bookmark.fill", text: "Marked", color: Theme.ink, dashed: false)
        case .pause:
            divider(
                symbol: "pause.circle.fill",
                text: marker.isOpen ? "Paused · off the record" : "Paused · off the record, nothing was transcribed",
                color: Theme.inkSoft, dashed: true)
        }
    }

    private var note: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkSoft)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.s) {
                    Eyebrow(text: "Your note", color: Theme.inkSoft)
                    Text(marker.time).font(TypeScale.stamp).foregroundStyle(Theme.inkFaint)
                    Spacer(minLength: 0)
                }
                Text(marker.text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.l - 2, style: .continuous).fill(Theme.sunken))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l - 2, style: .continuous)
                .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your note at \(marker.time): \(marker.text)")
    }

    private func divider(symbol: String, text: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 10) {
            rule(dashed: dashed)
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(text).font(TypeScale.captionStrong)
                Text(marker.isOpen ? "since \(marker.time)" : marker.time).font(TypeScale.stamp).foregroundStyle(Theme.inkFaint)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(dashed ? Theme.stroke : Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
            .fixedSize()
            rule(dashed: dashed)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rule(dashed: Bool) -> some View {
        if dashed { DashedRule() } else { Hairline() }
    }
}

/// "Add a note…" at the bottom of the live transcript. Return adds the note at the moment you
/// started typing it; the bookmark button (⌘B) marks the moment without text.
struct NoteComposer: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var typingSince: Date?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(focused ? Theme.ink : Theme.inkFaint)
                TextField("Add a note", text: $draft, prompt: Text("Add a note…").foregroundColor(Theme.inkFaint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit(submit)
                    .onChange(of: draft) { old, new in
                        if old.isEmpty && !new.isEmpty { typingSince = Date() }
                        if new.isEmpty { typingSince = nil }
                    }
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: 4) {
                        KeyHint("↩")
                        Text("to add").font(TypeScale.caption).foregroundStyle(Theme.inkFaint)
                    }
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .fieldChrome(focused: focused)
            .animation(Motion.quick, value: draft.isEmpty)
            Button(action: model.addMark) {
                Label("Mark", systemImage: "bookmark")
            }
            .buttonStyle(.secondary)
            .help("Mark this moment as important (⌘B)")
        }
        .readableColumn(gutter: Metrics.gutter - 8)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) { Hairline() }
        .disabled(!model.isRecording)
        .onAppear { focused = true }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.addNote(text, typingSince: typingSince)
        draft = ""
        typingSince = nil
        focused = true
    }
}

/// Round control beside the record button: pause ("off the record") and resume.
struct PauseButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        IconButton(
            symbol: model.paused ? "play.fill" : "pause.fill",
            label: model.paused ? "Resume recording" : "Pause recording",
            help: model.paused ? "Resume recording (⇧⌘P)" : "Pause: go off the record (⇧⌘P)",
            size: 40, style: model.paused ? .primary : .secondary,
            action: model.togglePause)
    }
}

/// The Call menu in the menu bar of the main window (mark, pause).
struct RecordingCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Call") {
            Button("Mark This Moment", action: model.addMark)
                .keyboardShortcut("b")
                .disabled(!model.isRecording)
            Button(model.paused ? "Resume Recording" : "Pause Recording", action: model.togglePause)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.isRecording)
        }
    }
}
