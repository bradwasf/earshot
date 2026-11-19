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

/// A note reads as the user's own aside (sans-serif on a dashed well, no speaker rule); marks
/// and pauses are slim dividers across the transcript.
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
                HStack(spacing: 7) {
                    Eyebrow(text: "Your note")
                    Spacer(minLength: 8)
                    Text(marker.time).font(.stamp(10.5)).foregroundStyle(Theme.inkFaint)
                }
                Text(marker.text)
                    .font(.ui(14, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.inkFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your note at \(marker.time): \(marker.text)")
    }

    private func divider(symbol: String, text: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 10) {
            rule(dashed: dashed)
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(text).font(.ui(11.5, .semibold))
                Text(marker.isOpen ? "since \(marker.time)" : marker.time).font(.stamp(10.5)).foregroundStyle(Theme.inkFaint)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.well))
            .fixedSize()
            rule(dashed: dashed)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func rule(dashed: Bool) -> some View {
        Line()
            .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : []))
            .frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
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
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(focused ? Theme.me : Theme.inkFaint)
            TextField("Add a note", text: $draft, prompt: Text("Add a note…").foregroundColor(Theme.inkFaint))
                .textFieldStyle(.plain)
                .font(.ui(13.5))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: draft) { old, new in
                    if old.isEmpty && !new.isEmpty { typingSince = Date() }
                    if new.isEmpty { typingSince = nil }
                }
            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("↩ to add").font(.ui(11)).foregroundStyle(Theme.inkFaint).fixedSize()
            }
            Button(action: model.addMark) {
                Label("Mark", systemImage: "bookmark")
            }
            .buttonStyle(GhostButtonStyle())
            .help("Mark this moment as important (⌘B)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(focused ? Theme.me.opacity(0.5) : Theme.hairline))
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
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
    @State private var hovering = false

    var body: some View {
        Button(action: model.togglePause) {
            Image(systemName: model.paused ? "play.fill" : "pause.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(model.paused ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.ink.opacity(0.85)))
                .frame(width: 42, height: 42)
                .background(
                    Circle().fill(
                        model.paused
                            ? AnyShapeStyle(Theme.accentGradient)
                            : AnyShapeStyle(hovering ? Theme.surfaceHover : Theme.surface))
                )
                .overlay(Circle().strokeBorder(model.paused ? .white.opacity(0.22) : Theme.hairline))
                .shadow(color: Color(hex: 0x0EA5E9).opacity(model.paused ? 0.4 : 0), radius: 10, y: 4)
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.snappy(duration: 0.18), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(model.paused ? "Resume recording (⇧⌘P)" : "Pause: go off the record (⇧⌘P)")
        .accessibilityLabel(model.paused ? "Resume recording" : "Pause recording")
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
