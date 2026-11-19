import EarshotCore
import SwiftUI

/// A round-cornered checkbox in the app's style (stock toggles look out of place on the cards).
struct ActionCheckbox: View {
    let done: Bool
    var tint: Color = Theme.tone(1)
    let toggle: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(done ? tint : (hovering && isEnabled ? tint.opacity(0.12) : Theme.surface))
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(done ? tint : (hovering && isEnabled ? tint : Theme.inkFaint), lineWidth: 1.3)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.surface)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .padding(3)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.snappy(duration: 0.16), value: done)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(done ? "Mark as not done" : "Mark as done")
        .accessibilityLabel(done ? "Done" : "Not done")
        .accessibilityAddTraits(done ? [.isSelected] : [])
        // Sit on the text's first baseline, like a list marker.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }
}

/// The owner of an action item. Items that are yours ("Me") get a solid chip so they stand out.
struct OwnerChip: View {
    let owner: String
    var accent: Color = Theme.tone(1)
    var compact = false

    var body: some View {
        let mine = owner.lowercased() == "me"
        let unassigned = owner.lowercased() == "unassigned"
        let color = unassigned ? Theme.inkFaint : (mine ? Theme.me : accent)
        Text(owner)
            .font(.ui(compact ? 10.5 : 11, .bold))
            .foregroundStyle(mine ? Theme.surface : (unassigned ? Theme.inkSoft : accent))
            .padding(.horizontal, compact ? 7 : 8)
            .padding(.vertical, compact ? 2 : 2.5)
            .background(Capsule().fill(mine ? color : color.opacity(0.14)))
            .fixedSize()
            .help(mine ? "Yours to do" : "Owner: \(owner)")
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
        if model.search.trimmingCharacters(in: .whitespaces).isEmpty, !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header(open: open)
                if !collapsed {
                    let shown = showAll ? entries : Array(entries.prefix(Self.preview))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 34) }
                            row(entry)
                        }
                        if entries.count > Self.preview {
                            Button {
                                withAnimation(.snappy(duration: 0.22)) { showAll.toggle() }
                            } label: {
                                Text(showAll ? "Show fewer" : "Show \(entries.count - Self.preview) more")
                                    .font(.ui(11.5, .semibold))
                                    .foregroundStyle(Theme.me)
                                    .padding(.vertical, 8)
                                    .padding(.leading, 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.bottom, 10)
            .animation(.snappy(duration: 0.22), value: entries.map(\.id))
        }
    }

    private func header(open: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "checklist").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tone(1))
                Eyebrow(text: "Open action items")
                Text("\(open)").font(.stamp(10.5)).foregroundStyle(Theme.inkFaint)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkFaint)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Spacer()
            }
            .padding(.leading, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show open action items" : "Hide open action items")
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ActionCheckbox(done: entry.item.done) { toggle(entry) }
                .disabled(!model.canEditActionItems)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let owner = entry.item.owner { OwnerChip(owner: owner, compact: true) }
                    Text(markdownInline(entry.item.task))
                        .font(.reading(14))
                        .foregroundStyle(entry.item.done ? Theme.inkFaint : Theme.ink)
                        .strikethrough(entry.item.done, color: Theme.inkFaint)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                CallLink(title: entry.call.title) { model.open(entry.call) }
            }
        }
        .padding(.vertical, 6)
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
            withAnimation(.snappy(duration: 0.25)) { _ = lingering.remove(entry.id) }
        }
    }
}

/// The call an action item came from, as a small link.
private struct CallLink: View {
    let title: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
            }
            .font(.ui(11.5, .medium))
            .foregroundStyle(hovering ? Theme.me : Theme.inkSoft)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open “\(title)”")
    }
}

private func markdownInline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}
