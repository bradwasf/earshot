import AppKit
import EarshotCore
import SwiftUI

@main
struct EarshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Earshot", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--appearance light|dark` overrides the system appearance (used for screenshots).
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--appearance"), index + 1 < arguments.count {
            NSApp.appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Finish and save an in-progress call before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRecording else { return .terminateNow }
        Task { @MainActor in
            await model.stopForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggle() }
            .keyboardShortcut("r")
            .disabled(model.isBusy)
        if model.isRecording {
            Text("Recording · \(TranscriptFormat.timestamp(model.elapsed))")
        } else if case .finishing(let message) = model.phase {
            Text(message)
        } else if case .loading(let message) = model.phase {
            Text(message)
        }
        Divider()
        Button("Show Earshot") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Calls Folder") { model.openCallsFolder() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Earshot") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
