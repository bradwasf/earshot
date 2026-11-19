import EarshotCore
import SwiftUI

/// summary.md broken into the pieces the cards need.
struct SummaryDocument {
    struct Section: Identifiable {
        let id: String
        let name: String
        var items: [String]
        var prose: [String]
    }

    var overview: String = ""
    var sections: [Section] = []
    var footnote: String?

    /// Returns nil when the text is not a structured summary (e.g. the "could not be generated" note).
    init?(markdown: String) {
        var current: Int?
        var inOverview = false
        var afterRule = false
        for raw in markdown.components(separatedBy: "\n") {
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
                let text = section.isActions ? ActionRow.parts(item).task : item
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
                    VStack(alignment: .leading, spacing: 12) {
                        if let document = SummaryDocument(markdown: markdown) {
                            if !document.overview.isEmpty { overview(document.overview) }
                            ForEach(document.sections) { section in
                                SectionCard(section: section)
                            }
                            if let footnote = document.footnote {
                                Text(inline(footnote))
                                    .font(.ui(11))
                                    .foregroundStyle(Theme.inkFaint)
                                    .padding(.horizontal, 4)
                                    .padding(.top, 2)
                            }
                        } else {
                            Card {
                                Text(reader.highlight(inline(Self.plain(markdown)), block: "summary-plain"))
                                    .font(.reading(14.5))
                                    .foregroundStyle(Theme.inkSoft)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .textSelection(.enabled)
                    .background(OverlayScrollers())
                }
                .onChange(of: reader.scrollRequest) { _, request in
                    guard let request, request.block.hasPrefix("summary-") else { return }
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(request.block, anchor: .center) }
                }
            }
        } else {
            VStack(spacing: 10) {
                if case .finishing(let message) = model.phase {
                    ProgressView().controlSize(.small)
                    Text(message).font(.ui(13.5, .medium)).foregroundStyle(Theme.inkSoft)
                    Text("The transcript is already saved. You can read it while this finishes.")
                        .font(.reading(13.5)).foregroundStyle(Theme.inkFaint)
                } else {
                    Text("No summary yet").font(.ui(17, .semibold)).foregroundStyle(Theme.ink)
                    Text("Use Regenerate summary below to write one from the transcript.")
                        .font(.reading(14)).foregroundStyle(Theme.inkSoft)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380, maxHeight: .infinity)
            .padding(28)
        }
    }

    private func overview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "In short", color: Theme.me)
            Text(reader.highlight(inline(text), block: "summary-overview"))
                .font(.reading(16))
                .lineSpacing(4.5)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.me.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.me.opacity(0.25)))
        .id("summary-overview")
    }

    /// The failure note is Markdown too; drop its heading and emphasis markers.
    static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

/// One list section of the summary, styled by what it holds.
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

    private var accent: Color {
        switch kind {
        case .actions: return Theme.tone(1)
        case .decisions: return Theme.tone(3)
        case .questions: return Theme.tone(2)
        case .points, .other: return Theme.inkSoft
        }
    }

    private var symbol: String {
        switch kind {
        case .actions: return "checklist"
        case .decisions: return "checkmark.seal.fill"
        case .questions: return "questionmark.circle.fill"
        case .points, .other: return "text.alignleft"
        }
    }

    private var isEmpty: Bool { section.isEmpty }

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    Eyebrow(text: section.name, color: accent)
                    Spacer()
                    if !isEmpty && kind != .other {
                        Text("\(section.items.count)").font(.stamp(10.5)).foregroundStyle(Theme.inkFaint)
                    }
                }
                if isEmpty {
                    Text("None recorded").font(.reading(14)).foregroundStyle(Theme.inkFaint)
                } else {
                    ForEach(Array(section.prose.enumerated()), id: \.offset) { index, line in
                        Text(reader.highlight(inline(line), block: section.blockID("p", index)))
                            .font(.reading(14.5)).foregroundStyle(Theme.ink).lineSpacing(3)
                            .id(section.blockID("p", index))
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        if kind == .actions {
                            ActionRow(item: item, accent: accent, block: section.blockID("i", index))
                                .id(section.blockID("i", index))
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(accent.opacity(0.75)).frame(width: 5, height: 5).offset(y: -2.5)
                                Text(reader.highlight(inline(item), block: section.blockID("i", index)))
                                    .font(.reading(14.5))
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
}

/// "- [ ] **Owner** — task" as an owner chip plus the task.
struct ActionRow: View {
    let item: String
    let accent: Color
    var block = ""
    @EnvironmentObject private var reader: CallReader

    private var parts: (owner: String?, task: String) { Self.parts(item) }

    static func parts(_ item: String) -> (owner: String?, task: String) {
        var text = item
        for prefix in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        guard text.hasPrefix("**"), let close = text.dropFirst(2).range(of: "**") else { return (nil, text) }
        let owner = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
        var task = String(text[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        for dash in ["—", "–", "-", ":"] where task.hasPrefix(dash) {
            task = String(task.dropFirst(dash.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return (owner, task.prefix(1).uppercased() + task.dropFirst())
    }

    var body: some View {
        let parts = parts
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let owner = parts.owner {
                let unassigned = owner.lowercased() == "unassigned"
                Text(owner)
                    .font(.ui(11, .bold))
                    .foregroundStyle(unassigned ? Theme.inkSoft : (owner == "Me" ? Theme.me : accent))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule().fill((unassigned ? Theme.inkFaint : (owner == "Me" ? Theme.me : accent)).opacity(0.14))
                    )
                    .fixedSize()
            }
            Text(reader.highlight(inline(parts.task), block: block))
                .font(.reading(14.5))
                .lineSpacing(3.5)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
