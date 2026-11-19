import EarshotCore
import SwiftUI

/// summary.md broken into the pieces the cards need.
struct SummaryDocument {
    struct Section: Identifiable {
        let id: String
        let name: String
        var items: [String]
        var prose: [String]
        /// Line in summary.md of each item (to tick action items off in place).
        var itemLines: [Int] = []
    }

    var overview: String = ""
    var sections: [Section] = []
    var footnote: String?

    /// Returns nil when the text is not a structured summary (e.g. the "could not be generated" note).
    init?(markdown: String) {
        var current: Int?
        var inOverview = false
        var afterRule = false
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("# ") { continue }
            if line == "---" {
                afterRule = true
                continue
            }
            if afterRule {
                footnote = line.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                continue
            }
            if line.hasPrefix("## ") {
                let name = String(line.dropFirst(3))
                inOverview = name.lowercased().contains("tl;dr")
                if inOverview {
                    current = nil
                } else {
                    sections.append(Section(id: "\(sections.count)-\(name)", name: name, items: [], prose: []))
                    current = sections.count - 1
                }
            } else if inOverview {
                overview += (overview.isEmpty ? "" : " ") + line
            } else if let current {
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    sections[current].items.append(String(line.dropFirst(2)))
                    sections[current].itemLines.append(index)
                } else {
                    sections[current].prose.append(line)
                }
            }
        }
        if overview.isEmpty && sections.isEmpty { return nil }
    }

    /// The text find-in-call searches, as the cards show it, with the ids of the views showing it.
    static func searchBlocks(_ markdown: String) -> [(id: String, text: String)] {
        guard let document = SummaryDocument(markdown: markdown) else {
            return [("summary-plain", String(inline(SummaryView.plain(markdown)).characters))]
        }
        var blocks: [(id: String, text: String)] = []
        if !document.overview.isEmpty { blocks.append(("summary-overview", String(inline(document.overview).characters))) }
        for section in document.sections where !section.isEmpty {
            for (index, line) in section.prose.enumerated() {
                blocks.append((section.blockID("p", index), String(inline(line).characters)))
            }
            for (index, item) in section.items.enumerated() {
                let text = section.isActions ? ActionItems.split(ActionItems.checkbox(item).text).task : item
                blocks.append((section.blockID("i", index), String(inline(text).characters)))
            }
        }
        return blocks
    }
}

extension SummaryDocument.Section {
    var isEmpty: Bool { items.allSatisfy { $0.lowercased().contains("none recorded") } && prose.isEmpty }
    var isActions: Bool { name.lowercased().contains("action") }
    func blockID(_ kind: String, _ index: Int) -> String { "summary-\(id)-\(kind)\(index)" }
}

struct SummaryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var reader: CallReader

    var body: some View {
        if let markdown = model.document?.summary {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        if let document = SummaryDocument(markdown: markdown) {
                            if !document.overview.isEmpty { overview(document.overview) }
                            ForEach(document.sections) { section in
                                SectionCard(section: section)
                            }
                            if let footnote = document.footnote {
                                Text(inline(footnote))
                                    .font(TypeScale.caption)
                                    .foregroundStyle(Theme.inkFaint)
                                    .tint(Theme.inkSoft)
                                    .padding(.horizontal, Space.xs)
                                    .padding(.top, Space.xs)
                            }
                        } else {
                            Card {
                                Text(reader.highlight(inline(Self.plain(markdown)), block: "summary-plain"))
                                    .font(TypeScale.readingSmall)
                                    .foregroundStyle(Theme.inkSoft)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .readableColumn()
                    .padding(.top, Space.s)
                    .padding(.bottom, Space.xl)
                    .textSelection(.enabled)
                    .background(OverlayScrollers())
                }
                .onChange(of: reader.scrollRequest) { _, request in
                    guard let request, request.block.hasPrefix("summary-") else { return }
                    withAnimation(Motion.standard) { proxy.scrollTo(request.block, anchor: .center) }
                }
            }
        } else if case .finishing(let message) = model.phase {
            EmptyState(title: message, message: "The transcript is already saved. You can read it while this finishes.") {
                ProgressView().controlSize(.small)
            } actions: {
                EmptyView()
            }
        } else {
            EmptyState(title: "No summary yet", message: "Earshot can write one from the transcript with your local model.") {
                Image(systemName: "text.badge.star").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.inkFaint)
            } actions: {
                Button { model.regenerateSummary() } label: { Label("Regenerate summary", systemImage: "arrow.clockwise") }
                    .buttonStyle(.secondary)
                    .disabled(model.phase != .idle || (model.document?.turns.isEmpty ?? true))
            }
        }
    }

    private func overview(_ text: String) -> some View {
        Card(style: .wash, padding: 18) {
            VStack(alignment: .leading, spacing: Space.s) {
                Eyebrow(text: "In short", color: Theme.inkSoft)
                Text(reader.highlight(inline(text), block: "summary-overview"))
                    .font(TypeScale.readingLede)
                    .lineSpacing(TypeScale.readingLeading)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id("summary-overview")
    }

    /// The failure note is Markdown too; drop its heading and emphasis markers.
    static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One list section of the summary, marked by what it holds.
private struct SectionCard: View {
    let section: SummaryDocument.Section
    @EnvironmentObject private var reader: CallReader

    private enum Kind {
        case points, decisions, actions, questions, other
    }

    private var kind: Kind {
        let name = section.name.lowercased()
        if name.contains("action") { return .actions }
        if name.contains("decision") { return .decisions }
        if name.contains("question") { return .questions }
        if name.contains("key") { return .points }
        return .other
    }

    private var symbol: String {
        switch kind {
        case .actions: return "checklist"
        case .decisions: return "checkmark.seal"
        case .questions: return "questionmark.circle"
        case .points, .other: return "text.alignleft"
        }
    }

    private var isEmpty: Bool { section.isEmpty }

    private func actionItem(_ index: Int) -> ActionItem {
        let state = ActionItems.checkbox(section.items[index])
        let line = index < section.itemLines.count ? section.itemLines[index] : -1
        return ActionItem(line: line, done: state.done ?? false, text: state.text)
    }

    /// "3", or "1/3 done" once action items are being ticked off.
    private var count: String {
        guard kind == .actions else { return "\(section.items.count)" }
        let done = section.items.indices.filter { actionItem($0).done }.count
        return done == 0 ? "\(section.items.count)" : "\(done)/\(section.items.count) done"
    }

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(
                    title: section.name, symbol: symbol, count: !isEmpty && kind != .other ? count : nil,
                    tint: Theme.inkSoft)
                if isEmpty {
                    Text("None recorded").font(TypeScale.readingSmall).italic().foregroundStyle(Theme.inkFaint)
                } else {
                    ForEach(Array(section.prose.enumerated()), id: \.offset) { index, line in
                        Text(reader.highlight(inline(line), block: section.blockID("p", index)))
                            .font(TypeScale.readingSmall).foregroundStyle(Theme.ink).lineSpacing(3.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(section.blockID("p", index))
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        if kind == .actions {
                            ActionRow(item: actionItem(index), block: section.blockID("i", index))
                                .id(section.blockID("i", index))
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 11) {
                                bullet
                                Text(reader.highlight(inline(item), block: section.blockID("i", index)))
                                    .font(TypeScale.readingSmall)
                                    .lineSpacing(3.5)
                                    .foregroundStyle(Theme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(section.blockID("i", index))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bullet: some View {
        switch kind {
        case .questions:
            Text("?").font(.system(size: 12, weight: .bold, design: .serif)).foregroundStyle(Theme.inkFaint).frame(width: 8)
        case .decisions:
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.inkFaint).frame(width: 8)
        default:
            Dot(color: Theme.inkFaint, size: 5).offset(y: -2.5).frame(width: 8)
        }
    }
}

/// "- [ ] **Owner** — task" as a checkbox, an owner chip and the task. Ticking writes summary.md.
private struct ActionRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var reader: CallReader
    let item: ActionItem
    var block = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Checkbox(done: item.done) {
                guard let folder = model.document?.folder else { return }
                model.setActionItem(item, in: folder, done: !item.done)
            }
            .disabled(!model.canEditActionItems || item.line < 0)
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                if let owner = item.owner { OwnerChip(owner: owner, names: model.document?.speakerNames ?? [:]) }
                Text(reader.highlight(inline(item.task), block: block))
                    .font(TypeScale.readingSmall)
                    .lineSpacing(3.5)
                    .foregroundStyle(item.done ? Theme.inkFaint : Theme.ink)
                    .strikethrough(item.done, color: Theme.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(item.done ? 0.8 : 1)
        }
    }
}
