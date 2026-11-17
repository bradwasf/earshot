import CoreAudio
import Darwin
import Foundation

/// A meeting app whose calls Earshot can notice.
public struct CallApp: Sendable, Hashable, Identifiable {
    public let id: String
    /// "Zoom", "Slack"…
    public let name: String
    /// What a call in this app is called: "Zoom call", "Slack huddle".
    public let callName: String
    /// Bundle identifiers of the app and its helper processes all start with one of these.
    public let bundlePrefixes: [String]

    public init(id: String, name: String, callName: String, bundlePrefixes: [String]) {
        self.id = id
        self.name = name
        self.callName = callName
        self.bundlePrefixes = bundlePrefixes
    }

    public static let known: [CallApp] = [
        CallApp(id: "zoom", name: "Zoom", callName: "Zoom call", bundlePrefixes: ["us.zoom."]),
        CallApp(id: "slack", name: "Slack", callName: "Slack huddle", bundlePrefixes: ["com.tinyspeck.slackmacgap"]),
        CallApp(id: "teams", name: "Teams", callName: "Teams call", bundlePrefixes: ["com.microsoft.teams"]),
        CallApp(id: "discord", name: "Discord", callName: "Discord call", bundlePrefixes: ["com.hnc.Discord"]),
        CallApp(
            id: "webex", name: "Webex", callName: "Webex call",
            bundlePrefixes: ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.webex.meetingmanager"]),
        // FaceTime (and iPhone calls relayed to the Mac) capture audio in avconferenced.
        CallApp(
            id: "facetime", name: "FaceTime", callName: "FaceTime call",
            bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"]),
    ]

    /// The known app that owns a process with this bundle identifier, if any.
    public static func match(bundleID: String, in apps: [CallApp] = known) -> CallApp? {
        let lowered = bundleID.lowercased()
        return apps.first { app in app.bundlePrefixes.contains { lowered.hasPrefix($0.lowercased()) } }
    }
}

/// Turns "which meeting apps hold the microphone right now" samples into joined / ended events.
///
/// A meeting app opens the microphone when you join a call and keeps it open (muted or not) until
/// you leave, so sustained microphone use is the join signal. The delays filter out blips such as
/// a device test or a reconnect.
public struct CallDetector: Sendable {
    public enum Event: Sendable, Equatable {
        case joined(CallApp)
        case ended(CallApp)
    }

    /// The microphone must be held this long before a call counts as joined.
    public var joinDelay: TimeInterval
    /// The microphone must be released this long before a call counts as over.
    public var endDelay: TimeInterval

    private var firstSeen: [CallApp: TimeInterval] = [:]
    private var lastSeen: [CallApp: TimeInterval] = [:]
    public private(set) var active: Set<CallApp> = []

    public init(joinDelay: TimeInterval = 2, endDelay: TimeInterval = 6) {
        self.joinDelay = joinDelay
        self.endDelay = endDelay
    }

    /// Feed one sample. `now` is any monotonic clock, in seconds.
    public mutating func update(using apps: Set<CallApp>, now: TimeInterval) -> [Event] {
        var events: [Event] = []
        for app in apps {
            lastSeen[app] = now
            if firstSeen[app] == nil { firstSeen[app] = now }
            if !active.contains(app), let first = firstSeen[app], now - first >= joinDelay {
                active.insert(app)
                events.append(.joined(app))
            }
        }
        for (app, last) in lastSeen where !apps.contains(app) && now - last >= endDelay {
            lastSeen[app] = nil
            firstSeen[app] = nil
            if active.remove(app) != nil { events.append(.ended(app)) }
        }
        return events.sorted { Self.order($0) < Self.order($1) }
    }

    public mutating func reset() {
        firstSeen = [:]
        lastSeen = [:]
        active = []
    }

    private static func order(_ event: Event) -> String {
        switch event {
        case .ended(let app): return "0-\(app.id)"
        case .joined(let app): return "1-\(app.id)"
        }
    }
}

/// Reads from Core Audio which processes are capturing audio. Needs no privacy permission:
/// it reports that a process holds an input stream, never the audio itself.
public enum MicrophoneActivity {
    /// Bundle identifiers of every process currently running audio input, excluding this one.
    public static func bundleIDsCapturingAudio() -> Set<String> {
        var result: Set<String> = []
        let me = getpid()
        for object in processObjects() {
            guard let running: UInt32 = value(object, kAudioProcessPropertyIsRunningInput), running != 0,
                let pid: pid_t = value(object, kAudioProcessPropertyPID), pid != me
            else { continue }
            if let bundle = bundleID(object), !bundle.isEmpty { result.insert(bundle) }
            // Helper processes sometimes report no identifier (or an unrelated one): add the app
            // bundle that contains the executable.
            if let owner = owningAppBundleID(pid: pid) { result.insert(owner) }
        }
        return result
    }

    /// The known meeting apps that hold the microphone right now.
    public static func callAppsCapturingAudio(apps: [CallApp] = CallApp.known) -> Set<CallApp> {
        Set(bundleIDsCapturingAudio().compactMap { CallApp.match(bundleID: $0, in: apps) })
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func value<T: BinaryInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Identifier of the outermost .app bundle containing the process's executable
    /// ("…/Slack.app/Contents/Frameworks/Slack Helper.app/…" → Slack's).
    static func owningAppBundleID(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return owningAppBundleID(executablePath: String(cString: buffer))
    }

    static func owningAppBundleID(executablePath: String) -> String? {
        var url = URL(fileURLWithPath: "/")
        for component in URL(fileURLWithPath: executablePath).pathComponents.dropFirst() {
            url.appendPathComponent(component)
            if component.hasSuffix(".app") { return Bundle(url: url)?.bundleIdentifier }
        }
        return nil
    }
}
