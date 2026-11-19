import EarshotCore
import SwiftUI

/// The owner of an action item. Yours (owned by "Me", or by the name "Me" was given in that
/// call) is a filled chip so it stands out; a speaker of the call gets that speaker's colour.
struct OwnerChip: View {
    let owner: String
    /// The call's speaker names (label → name), from transcript.md.
    var names: [String: String] = [:]
    var compact = false

    var body: some View {
        let label = SpeakerNames.label(of: owner, names: names)
        let mine = label == "Me"
        Chip(text: owner, style: style(label: label, mine: mine), compact: compact)
            .help(mine ? "Yours to do" : "Owner: \(owner)")
            .accessibilityLabel(mine ? "Yours: \(owner)" : "Owner: \(owner)")
    }

    private func style(label: String?, mine: Bool) -> Chip.Style {
        if mine { return .solid(Theme.me) }
        if let label { return .soft(Theme.tone(Theme.tone(label: label))) }
        return .neutral
    }
}

/// Home screen: the unticked action items of recent calls, newest call first. Ticking one
/// writes it back to that call's summary.md. Hidden when there are none or while searching.
struct OpenActionItemsSection: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("openActionItemsCollapsed") private var collapsed = false
    @State private var showAll = false
    /// Items ticked a moment ago: they stay visible (as done) briefly, so a slip can be undone.
    @State private var lingering: Set<String> = []

    /// Calls older than this no longer contribute their open items.
    private static let window: TimeInterval = 30 * 24 * 3600
    private static let preview = 4

    private struct Entry: Identifiable {
        let call: SavedCall
        let item: ActionItem
        var id: String { "\(call.folder.path)#\(item.line)" }
    }

    private var entries: [Entry] {
        let since = Date().addingTimeInterval(-Self.window)
        return model.library.filter { $0.date >= since }.flatMap { call in
            call.actionItems.compactMap { item in
                let entry = Entry(call: call, item: item)
                return !item.done || lingering.contains(entry.id) ? entry : nil
            }
        }
    }

    var body: some View {
        let entries = entries
        let open = entries.filter { !$0.item.done }.count
        let mine = entries.filter { !$0.item.done && $0.item.isMine(names: $0.call.speakerNames) }.count
        if model.search.trimmingCharacters(in: .whitespaces).isEmpty, !entries.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                header(open: open, mine: mine)
                if !collapsed {
                    let shown = showAll ? entries : Array(entries.prefix(Self.preview))
                    Card(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Hairline().padding(.leading, 42).padding(.trailing, 16) }
                                row(entry)
                            }
                            if entries.count > Self.preview {
                                Hairline().padding(.horizontal, 16)
                                Button {
                                    withAnimation(Motion.standard) { showAll.toggle() }
                                } label: {
                                    Label(
                                        showAll ? "Show fewer" : "Show \(entries.count - Self.preview) more",
                                        systemImage: showAll ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.ghost(.small))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Motion.standard, value: entries.map(\.id))
        }
    }

    private func header(open: Int, mine: Int) -> some View {
        Button {
            withAnimation(Motion.standard) { collapsed.toggle() }
        } label: {
            SectionHeader(title: "Open action items", symbol: "checklist", count: "\(open)") {
                HStack(spacing: Space.s) {
                    if mine > 0 { Chip(text: "\(mine) yours", style: .soft(Theme.me), compact: true) }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.inkFaint)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(collapsed ? "Show open action items" : "Hide open action items")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Checkbox(done: entry.item.done) { toggle(entry) }
                .disabled(!model.canEditActionItems)
            VStack(alignment: .leading, spacing: 5) {
                Text(inline(entry.item.task))
                    .font(TypeScale.readingCompact)
                    .foregroundStyle(entry.item.done ? Theme.inkFaint : Theme.ink)
                    .strikethrough(entry.item.done, color: Theme.inkFaint)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if let owner = entry.item.owner {
                        OwnerChip(owner: owner, names: entry.call.speakerNames, compact: true)
                    }
                    LinkButton(
                        title: entry.call.title, trailingSymbol: "arrow.up.right", font: TypeScale.caption,
                        color: Theme.inkFaint
                    ) { model.open(entry.call) }
                    .help("Open “\(entry.call.title)”")
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
    }

    private func toggle(_ entry: Entry) {
        let done = !entry.item.done
        model.setActionItem(entry.item, in: entry.call.folder, done: done)
        guard done else {
            lingering.remove(entry.id)
            return
        }
        lingering.insert(entry.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(Motion.standard) { _ = lingering.remove(entry.id) }
        }
    }
}
