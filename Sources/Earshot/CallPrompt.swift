import AppKit
import EarshotCore
import SwiftUI

/// Shows `CallPrompt`s in a small floating card at the top-right of the screen. The card never
/// takes focus from the call: it is a non-activating panel that floats over every Space,
/// full-screen apps included.
@MainActor
final class PromptPanelController {
    private(set) var current: CallPrompt?
    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?

    func show(_ prompt: CallPrompt, model: AppModel) {
        current = prompt
        let lifetime: Double
        switch prompt {
        case .join, .ended: lifetime = 30
        case .transcribing, .stopped: lifetime = 3
        case .stopping: lifetime = CallPrompt.stopDelay
        }

        let view = PromptCard(prompt: prompt, lifetime: lifetime, model: model) { [weak self] in self?.dismiss() }
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = self.panel ?? Self.makePanel()
        let wasVisible = self.panel != nil && panel.isVisible
        self.panel = panel
        panel.contentView = hosting

        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: area.maxX - size.width - 4, y: area.maxY - size.height - 2, width: size.width, height: size.height)
        if wasVisible {
            panel.setFrame(frame, display: true)
        } else {
            // Slide in from the right edge.
            panel.setFrame(frame.offsetBy(dx: 24, dy: 0), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }

        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled, self?.current == prompt else { return }
            // The countdown ran out without "Keep recording": stop the call.
            if case .stopping = prompt { model.acceptCallEnded() } else { self?.dismiss() }
        }
    }

    func dismiss() {
        timeout?.cancel()
        timeout = nil
        current = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                // A new prompt may have arrived while this one faded.
                if self?.current == nil { panel.orderOut(nil) } else { panel.alphaValue = 1 }
            }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = PromptPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow inside the (transparent) window.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }
}

/// Borderless panels refuse key status by default; buttons need it to track clicks.
private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the card press a button even though another app is active.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card itself: the calling app's icon, a question and two answers.
private struct PromptCard: View {
    let prompt: CallPrompt
    let lifetime: Double
    let model: AppModel
    let dismiss: () -> Void

    private let shownAt = Date()

    private var app: CallApp {
        switch prompt {
        case .join(let app), .ended(let app), .transcribing(let app), .stopping(let app), .stopped(let app): return app
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    if case .stopping = prompt {
                        TimelineView(.periodic(from: shownAt, by: 1)) { context in
                            let left = max(1, Int((lifetime - context.date.timeIntervalSince(shownAt)).rounded(.up)))
                            Text("Stopping in \(left) s").font(TypeScale.headline).foregroundStyle(Theme.ink)
                                .monospacedDigit()
                                .contentTransition(.numericText(countsDown: true))
                                .animation(Motion.standard, value: left)
                        }
                    } else {
                        Text(title).font(TypeScale.headline).foregroundStyle(Theme.ink)
                    }
                    Text(detail)
                        .font(TypeScale.callout)
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !isNotice {
                HStack(spacing: Space.s) {
                    Button(action: primary) {
                        Text(primaryLabel).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(EarshotButtonStyle(kind: isEnded ? .record : .primary))
                    Button(action: dismiss) {
                        Text(isEnded ? "Keep recording" : "Not now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondary)
                }
            }
        }
        .padding(Space.l)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.l + 2, style: .continuous).fill(Theme.surface))
        .overlay(alignment: .bottomLeading) {
            // Time left before the card goes away on its own.
            if !isNotice {
                // Driven by the clock rather than an implicit animation, which would also
                // animate the card's first layout.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    Capsule()
                        .fill(isEnded ? Theme.record.opacity(0.55) : Theme.inkFaint.opacity(0.5))
                        .frame(height: 2)
                        .scaleEffect(
                            x: max(0, 1 - context.date.timeIntervalSince(shownAt) / lifetime), y: 1, anchor: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 5)
                .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.l + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.l + 2, style: .continuous).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.20), radius: 16, y: 7)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) \(detail)")
    }

    /// The call looks over: the card offers to stop (now, or after a countdown).
    private var isEnded: Bool { prompt.offersToStop }

    private var isTranscribing: Bool {
        if case .transcribing = prompt { return true }
        return false
    }

    /// A confirmation without buttons that goes away on its own.
    private var isNotice: Bool {
        switch prompt {
        case .transcribing, .stopped: return true
        case .join, .ended, .stopping: return false
        }
    }

    private var title: String {
        switch prompt {
        case .join: return "Start transcribing?"
        case .ended: return "Stop transcribing?"
        case .transcribing: return model.isBusy && !model.isRecording ? "Getting ready…" : "Transcribing"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        }
    }

    private var detail: String {
        switch prompt {
        case .join(let app): return "You joined a \(app.callName)."
        case .ended(let app): return "The \(app.callName) looks like it ended."
        case .transcribing:
            return model.hotKey.state == .registered
                ? "Stop any time with \(GlobalHotKey.display) or from the menu bar."
                : "Stop any time from the menu bar or Earshot."
        case .stopping(let app): return "The \(app.callName) looks like it ended."
        case .stopped:
            return UserDefaults.standard.bool(forKey: Preference.summarize)
                ? "Saving the transcript, then the summary."
                : "Saving the transcript."
        }
    }

    private var primaryLabel: String {
        switch prompt {
        case .stopping: return "Stop now"
        case .ended: return "Stop & summarize"
        default: return "Transcribe"
        }
    }

    private func primary() {
        switch prompt {
        case .join(let app): model.acceptCall(app)
        case .ended, .stopping: model.acceptCallEnded()
        case .transcribing, .stopped: dismiss()
        }
    }

    @ViewBuilder
    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = Self.icon(for: app) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink).frame(width: 40, height: 40)
                    .overlay(Image(systemName: "waveform").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.onInk))
            }
            if isTranscribing || isEnded {
                Circle().fill(Theme.record).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                    .offset(x: 3, y: 3)
            } else if case .stopped = prompt {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.ink).frame(width: 12, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.surface, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
        }
    }

    /// The meeting app's own icon, when it is running or installed.
    private static func icon(for app: CallApp) -> NSImage? {
        let running = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleIdentifier.flatMap { CallApp.match(bundleID: $0, in: [app]) } != nil
        }
        if let icon = running?.icon { return icon }
        let installed: [String: String] = [
            "zoom": "us.zoom.xos", "slack": "com.tinyspeck.slackmacgap", "teams": "com.microsoft.teams2",
            "discord": "com.hnc.Discord", "webex": "com.cisco.webexmeetingsapp", "facetime": "com.apple.FaceTime",
        ]
        guard let bundle = installed[app.id], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Slack settings

/// The Slack webhook URL lets anyone who has it post to the channel, so it is kept in the
/// login keychain rather than in the preferences file.
enum SlackSettings {
    private static let service = "local.earshot.app.slack-webhook"
    private static let account = "default"

    /// Posts go out on a session that keeps no cookies or cache.
    static let session = URLSession(configuration: .ephemeral)

    static var webhookURL: URL? { webhook.flatMap(SlackWebhook.validated) }

    static var webhook: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            var item = base
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrLabel as String] = "Earshot Slack webhook"
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
