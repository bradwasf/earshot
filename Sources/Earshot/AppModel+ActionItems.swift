import AppKit
import EarshotCore
import UniformTypeIdentifiers

/// Ticking off action items, and the exports that write files or copy just the checklist.
extension AppModel {
    // MARK: - Action items

    /// False while a summary is being written (it would replace the file being ticked).
    var canEditActionItems: Bool {
        if case .finishing = phase { return false }
        return true
    }

    /// Ticks or unticks one action item in a call's summary.md, changing only that line.
    func setActionItem(_ item: ActionItem, in folder: URL, done: Bool) {
        guard canEditActionItems else { return }
        do {
            let summary = try ActionItems.setDone(done, for: item, folder: folder)
            if document?.folder == folder { document?.summary = summary }
            if let index = library.firstIndex(where: { $0.folder == folder }) {
                library[index].actionItems = ActionItems.parse(summary)
            }
        } catch {
            warnings.append("Could not update the action item: \(error.localizedDescription)")
            if document?.folder == folder { document?.summary = CallLibrary.summary(folder: folder) }
            refreshLibrary()
        }
    }

    // MARK: - Export

    var hasActionItems: Bool { summaryExport?.actionItems != nil }

    /// Just the checklist with owners: rich text, with a Markdown task list as plain text.
    func copyActionItems() {
        guard let export = summaryExport, let markdown = export.actionItemsMarkdown, let html = export.actionItemsHTML
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("<meta charset=\"utf-8\">" + html, forType: .html)
        pasteboard.setString(markdown, forType: .string)
        show(Toast(text: "Action items copied"))
    }

    /// The transcript with the user's notes, marks and pauses in place, as in the window.
    private var exportLines: [CallExport.Entry] {
        guard let document else { return [] }
        return TranscriptRow.merge(turns: document.turns, markers: document.markers).map { row in
            switch row {
            case .turn(let turn): return .turn(time: turn.time, label: turn.label, text: turn.text)
            case .marker(let marker):
                let markdown: String
                switch marker.kind {
                case .note: markdown = "> **[\(marker.time)] Note:** \(marker.text)"
                case .mark: markdown = "> **[\(marker.time)] Marked**"
                case .pause: markdown = "> **[\(marker.time)] Paused** — off the record"
                }
                return .aside(markdown: markdown, plain: row.plainText)
            }
        }
    }

    /// One .md file with the summary and the full transcript.
    func saveMarkdown() {
        guard let document, summaryExport != nil || canExportTranscript else { return }
        let text = CallExport.markdown(
            summary: summaryExport, title: document.title, detail: document.detail, entries: exportLines)
        save(
            text, name: CallExport.fileName(document.title, extension: "md"),
            type: UTType(filenameExtension: "md") ?? .plainText, confirmation: "Saved as Markdown")
    }

    /// The transcript as a plain .txt file (the same text as Copy transcript).
    func saveTranscriptText() {
        guard let document, canExportTranscript else { return }
        let text = CallExport.transcriptText(title: document.title, detail: document.detail, entries: exportLines)
        save(
            text, name: CallExport.fileName(document.title, extension: "txt"), type: .plainText,
            confirmation: "Transcript saved")
    }

    private func save(_ text: String, name: String, type: UTType, confirmation: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self?.show(Toast(text: confirmation, symbol: "arrow.down.doc.fill"))
            } catch {
                self?.warnings.append("Could not save the file: \(error.localizedDescription)")
            }
        }
        // Present after the Export popover has closed, as a sheet on the main window.
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible })
                ?? NSApp.mainWindow
            {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(panel.runModal())
            }
        }
    }
}
