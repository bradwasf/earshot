import EarshotCore
import SwiftUI

/// "Export" on a finished call: a small menu of ways to take the summary elsewhere.
struct ExportButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .buttonStyle(GhostButtonStyle())
            .help("Copy or send this call")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ExportMenu { open = false }
                    .environmentObject(model)
            }
            .background {
                // ⇧⌘C copies for Slack without opening the menu.
                Button("") { model.copy(.slack) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear {
                // `--show-export` opens the menu at launch (used for screenshots).
                if CommandLine.arguments.contains("--show-export") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { open = true }
                }
            }
    }
}

private struct ExportMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    let close: () -> Void

    var body: some View {
        let hasSummary = model.summaryExport != nil
        VStack(alignment: .leading, spacing: 2) {
            ExportRow(
                symbol: "number", tint: Theme.tone(3), title: "Copy for Slack",
                detail: hasSummary ? "Formatted summary, ready to paste" : "There is no summary yet",
                shortcut: "⇧⌘C", enabled: hasSummary
            ) {
                model.copy(.slack)
                close()
            }
            ExportRow(
                symbol: "paperplane.fill", tint: Theme.tone(1), title: "Send to Slack",
                detail: !model.slackReady
                    ? "Add a channel webhook in Settings"
                    : hasSummary ? "Post the summary to your channel" : "There is no summary yet",
                enabled: !model.slackReady || hasSummary
            ) {
                if model.slackReady { model.sendToSlack() } else { openSettings() }
                close()
            }
            ExportRow(
                symbol: "sparkles", tint: Theme.tone(2), title: "Send to Grok Bot",
                detail: !model.grokBotInstalled
                    ? "Grok Bot isn’t installed"
                    : model.canExportTranscript ? "Open the transcript in a new prompt" : "There is no transcript yet",
                enabled: model.grokBotInstalled && model.canExportTranscript
            ) {
                model.sendToGrokBot()
                close()
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
            ExportRow(
                symbol: "doc.on.doc.fill", tint: Theme.me, title: "Copy summary",
                detail: "Rich text, with Markdown as plain text", enabled: hasSummary
            ) {
                model.copy(.markdown)
                close()
            }
            ExportRow(
                symbol: "text.quote", tint: Theme.tone(2), title: "Copy transcript",
                detail: "Every line, with speakers and times", enabled: model.canExportTranscript
            ) {
                model.copy(.transcript)
                close()
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(Theme.surface)
        .presentationBackground(Theme.surface)
    }
}

private struct ExportRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var shortcut: String?
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(13, .semibold)).foregroundStyle(Theme.ink)
                    Text(detail).font(.ui(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let shortcut {
                    Text(shortcut).font(.stamp(10.5)).foregroundStyle(Theme.inkFaint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering && enabled ? Theme.well : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// A short confirmation that floats above the footer.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tone(1))
            Text(toast.text).font(.ui(12.5, .semibold)).foregroundStyle(Theme.background)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.ink))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}

/// The finished call's title. Click it (or the pencil) to rename the call.
struct EditableTitle: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var title: String { model.document?.title ?? "Call" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if editing {
                TextField("Call title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.ui(22, .semibold))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                Text(title)
                    .font(.ui(22, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .onTapGesture(perform: begin)
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkFaint)
                    .opacity(hovering && model.phase == .idle ? 1 : 0)
                    .onTapGesture(perform: begin)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering = $0 }
        .help("Click to rename this call")
        .onChange(of: model.document?.folder) { _, _ in editing = false }
    }

    private func begin() {
        guard model.phase == .idle else { return }
        draft = title
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        model.renameCurrentCall(to: draft)
    }
}

/// Deletes the open call. The first click arms the button; the second moves the call to the Trash.
struct TrashButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var armed = false

    var body: some View {
        Button {
            if armed, let folder = model.document?.folder {
                armed = false
                model.trash(folder)
            } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        } label: {
            if armed {
                Label("Move to Trash?", systemImage: "trash").foregroundStyle(Theme.record)
            } else {
                Image(systemName: "trash").frame(height: 15)
            }
        }
        .buttonStyle(GhostButtonStyle())
        .disabled(model.phase != .idle)
        .help(armed ? "Click again to move this call to the Trash" : "Move this call to the Trash")
        .accessibilityLabel(armed ? "Confirm: move this call to the Trash" : "Move this call to the Trash")
        .animation(.snappy(duration: 0.18), value: armed)
    }
}

/// Compact search box for the list of recent calls.
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            TextField("Search calls", text: $text)
                .textFieldStyle(.plain)
                .font(.ui(12.5))
                .foregroundStyle(Theme.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: 190)
        .background(Capsule().fill(Theme.well))
    }
}
