import EarshotCore
import SwiftUI

/// "Export" on a finished call: a small menu of ways to take the summary elsewhere.
struct ExportButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .buttonStyle(.secondary)
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
            .background {
                // ⌥⌘C copies the action items, ⇧⌘S saves the call as Markdown.
                VStack {
                    Button("") { model.copyActionItems() }.keyboardShortcut("c", modifiers: [.command, .option])
                    Button("") { model.saveMarkdown() }.keyboardShortcut("s", modifiers: [.command, .shift])
                }
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
        VStack(alignment: .leading, spacing: 1) {
            MenuSectionLabel("Share")
            ExportRow(
                symbol: "number", title: "Copy for Slack",
                detail: hasSummary ? "Formatted summary, ready to paste" : "There is no summary yet",
                shortcut: "⇧⌘C", enabled: hasSummary
            ) {
                model.copy(.slack)
                close()
            }
            ExportRow(
                symbol: "paperplane", title: "Send to Slack",
                detail: !model.slackReady
                    ? "Add a channel webhook in Settings"
                    : hasSummary ? "Post the summary to your channel" : "There is no summary yet",
                enabled: !model.slackReady || hasSummary
            ) {
                if model.slackReady { model.sendToSlack() } else { openSettings() }
                close()
            }
            ExportRow(
                symbol: "sparkles", title: "Send to Grok Bot",
                detail: !model.grokBotInstalled
                    ? "Grok Bot isn’t installed"
                    : model.canExportTranscript ? "Open the transcript in a new prompt" : "There is no transcript yet",
                enabled: model.grokBotInstalled && model.canExportTranscript
            ) {
                model.sendToGrokBot()
                close()
            }
            MenuDivider()
            MenuSectionLabel("Copy")
            ExportRow(
                symbol: "doc.on.doc", title: "Copy summary",
                detail: "Rich text, with Markdown as plain text", enabled: hasSummary
            ) {
                model.copy(.markdown)
                close()
            }
            ExportRow(
                symbol: "checklist", title: "Copy action items",
                detail: model.hasActionItems ? "The checklist with owners" : "There are no action items",
                shortcut: "⌥⌘C", enabled: model.hasActionItems
            ) {
                model.copyActionItems()
                close()
            }
            ExportRow(
                symbol: "text.quote", title: "Copy transcript",
                detail: "Every line, with speakers and times", enabled: model.canExportTranscript
            ) {
                model.copy(.transcript)
                close()
            }
            MenuDivider()
            MenuSectionLabel("Save")
            ExportRow(
                symbol: "arrow.down.doc", title: "Save as Markdown…",
                detail: "Summary and transcript in one file", shortcut: "⇧⌘S",
                enabled: hasSummary || model.canExportTranscript
            ) {
                close()
                model.saveMarkdown()
            }
            ExportRow(
                symbol: "doc.plaintext", title: "Save transcript as text…",
                detail: "A plain .txt file, one line per turn", enabled: model.canExportTranscript
            ) {
                close()
                model.saveTranscriptText()
            }
        }
        .padding(6)
        .frame(width: 330)
        .background(Theme.surface)
        .presentationBackground(Theme.surface)
    }
}

private struct ExportRow: View {
    let symbol: String
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(hovering && enabled ? Theme.surface : Theme.sunken))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(TypeScale.bodyStrong).foregroundStyle(Theme.ink)
                    Text(detail).font(TypeScale.caption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let shortcut { KeyHint(shortcut) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(hovering && enabled ? Theme.wash : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .opacity(enabled ? 1 : 0.42)
            .animation(Motion.quick, value: hovering)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityHint(detail)
    }
}

private struct MenuSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Eyebrow(text: text).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
    }
}

private struct MenuDivider: View {
    var body: some View { Hairline().padding(.vertical, 5).padding(.horizontal, 8) }
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
                    .font(TypeScale.display)
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                Text(title)
                    .font(TypeScale.display)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .onTapGesture(perform: begin)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint("Click to rename this call")
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
                Image(systemName: "trash").frame(minWidth: 14)
            }
        }
        .buttonStyle(.ghost(.small))
        .disabled(model.phase != .idle)
        .help(armed ? "Click again to move this call to the Trash" : "Move this call to the Trash")
        .accessibilityLabel(armed ? "Confirm: move this call to the Trash" : "Move this call to the Trash")
        .animation(Motion.quick, value: armed)
    }
}
