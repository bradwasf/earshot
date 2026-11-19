import AVFoundation
import AppKit
import EarshotCore
import SwiftUI

/// State for reading a finished call: find in call, playing the recording from a line, and
/// naming speakers. Kept apart from `AppModel` so that typing a query or the playback clock
/// redraws only the call screen.
@MainActor
final class CallReader: ObservableObject {
    /// One find match: a range of characters in a block of text (a turn, or a line of the summary).
    struct Hit: Equatable {
        let block: String
        let range: Range<Int>
    }

    /// Asks the visible scroll view to bring a block into view.
    struct ScrollRequest: Equatable {
        let block: String
        let id = UUID()
    }

    // Find
    @Published var findOpen = false
    @Published var query = "" {
        didSet { if query != oldValue { refreshMatches(scroll: true) } }
    }
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var current = 0
    /// Bumped to move keyboard focus into the find field.
    @Published private(set) var focusRequest = 0
    @Published private(set) var scrollRequest: ScrollRequest?

    // Playback
    @Published private(set) var playingTurn: String?
    /// The call has a recording that can be played.
    @Published private(set) var hasAudio = false
    @Published var follow = true

    /// The turn whose speaker is being renamed (its tag shows the name editor).
    @Published var renamingTurn: String?

    let player = CallPlayer()
    private var document: CallDocument?
    private var tab: AppModel.Tab = .transcript
    private var hitsByBlock: [String: [(index: Int, range: Range<Int>)]] = [:]
    private var keyMonitor: Any?

    init() {
        player.onTick = { [weak self] time in self?.playbackMoved(to: time) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    // MARK: Following the window

    /// Called whenever the call on screen changes (opened, reloaded, renamed, closed).
    func documentChanged(from old: CallDocument?, to new: CallDocument?) {
        document = new
        guard let new else {
            reset()
            return
        }
        if old?.folder != new.folder {
            // A rename moves the folder; the open audio file keeps playing from its new place.
            let moved = old.map { !FileManager.default.fileExists(atPath: $0.folder.path) && $0.turns == new.turns } ?? false
            if !moved {
                reset()
                player.load(new.audioURL)
                hasAudio = player.available
            }
        }
        if renamingTurn != nil, !new.turns.contains(where: { $0.id == renamingTurn }) { renamingTurn = nil }
        refreshMatches(scroll: false)
        playbackMoved(to: player.time)
    }

    func tabChanged(to tab: AppModel.Tab) {
        guard tab != self.tab else { return }
        self.tab = tab
        refreshMatches(scroll: true)
    }

    /// Leaving the call (or starting a recording): stop playback and close the find bar.
    func reset() {
        player.unload()
        hasAudio = false
        playingTurn = nil
        renamingTurn = nil
        findOpen = false
        query = ""
        hits = []
        hitsByBlock = [:]
    }

    // MARK: Find

    /// ⌘F: shows the find bar and puts the cursor in it.
    func showFind() {
        guard document != nil else { return }
        findOpen = true
        focusRequest += 1
    }

    func closeFind() {
        findOpen = false
        query = ""
    }

    /// Opens the find bar on `query` (from the home screen's search) and returns the tab that
    /// shows matches: the transcript if it has any, else the summary, else `preferring`.
    func find(_ query: String, in document: CallDocument, preferring: AppModel.Tab) -> AppModel.Tab {
        self.document = document
        findOpen = true
        self.query = query
        if !TextSearch.matches(query, in: Self.blocks(document, tab: .transcript).map(\.text)).isEmpty {
            return .transcript
        }
        if !TextSearch.matches(query, in: Self.blocks(document, tab: .summary).map(\.text)).isEmpty { return .summary }
        return preferring
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard !hits.isEmpty else { return }
        current = (current + delta + hits.count) % hits.count
        scrollRequest = ScrollRequest(block: hits[current].block)
    }

    var countText: String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return hits.isEmpty ? "No matches" : "\(current + 1) of \(hits.count)"
    }

    private func refreshMatches(scroll: Bool) {
        guard findOpen, let document, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            if !hits.isEmpty { hits = [] }
            hitsByBlock = [:]
            return
        }
        let blocks = Self.blocks(document, tab: tab)
        let found = TextSearch.matches(query, in: blocks.map(\.text)).map { Hit(block: blocks[$0.block].id, range: $0.range) }
        let previous = hits.indices.contains(current) ? hits[current] : nil
        hits = found
        hitsByBlock = Dictionary(grouping: found.enumerated().map { ($0.offset, $0.element) }, by: \.1.block)
            .mapValues { $0.map { (index: $0.0, range: $0.1.range) } }
        // Stay on the same match when the text around it changes (e.g. a speaker was renamed).
        current = previous.flatMap { found.firstIndex(of: $0) } ?? 0
        if scroll, found.indices.contains(current) { scrollRequest = ScrollRequest(block: found[current].block) }
    }

    /// The searchable text of a tab, in reading order, with the ids its views use.
    static func blocks(_ document: CallDocument, tab: AppModel.Tab) -> [(id: String, text: String)] {
        switch tab {
        case .transcript: return document.turns.map { ($0.id, $0.text) }
        case .summary: return document.summary.map(SummaryDocument.searchBlocks) ?? []
        }
    }

    /// `text` with this block's matches marked; the current match stands out.
    func highlight(_ text: AttributedString, block: String) -> AttributedString {
        guard findOpen, let ranges = hitsByBlock[block] else { return text }
        var result = text
        let count = result.characters.count
        for hit in ranges where hit.range.upperBound <= count {
            let lower = result.characters.index(result.startIndex, offsetBy: hit.range.lowerBound)
            let upper = result.characters.index(result.startIndex, offsetBy: hit.range.upperBound)
            result[lower..<upper].backgroundColor = hit.index == current ? Theme.findCurrent : Theme.findMatch
        }
        return result
    }

    func highlight(_ text: String, block: String) -> AttributedString {
        highlight(AttributedString(text), block: block)
    }

    // MARK: Playback

    /// Plays the recording from a turn (a second early, so its first word is not clipped).
    func play(from turn: DisplayTurn) {
        guard let start = turn.start else { return }
        player.play(from: max(0, start - 1))
    }

    private func playbackMoved(to time: Double) {
        guard player.started, let turns = document?.turns else {
            if playingTurn != nil { playingTurn = nil }
            return
        }
        // The last turn that began before the playhead (a second of grace for the early start).
        let id = turns.last { ($0.start ?? .infinity) <= time + 1.05 }?.id ?? turns.first?.id
        guard id != playingTurn else { return }
        playingTurn = id
        if follow, player.isPlaying, let id { scrollRequest = ScrollRequest(block: id) }
    }

    // MARK: Keys

    /// Space plays and pauses, Esc closes the find bar, unless a text field has the keyboard.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard document != nil, let window = event.window, window.identifier?.rawValue.hasPrefix("main") == true,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        switch event.keyCode {
        case 49 where player.available:  // Space
            player.toggle()
            return true
        case 53 where findOpen:  // Esc
            closeFind()
            return true
        default:
            return false
        }
    }
}

/// The call's audio.m4a (left = Me, right = Them), played with AVAudioPlayer.
@MainActor
final class CallPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let rates: [Float] = [1, 1.5, 2]

    @Published private(set) var available = false
    @Published private(set) var isPlaying = false
    /// True once playback has been started for this call (until it is unloaded).
    @Published private(set) var started = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1 {
        didSet { player?.rate = rate }
    }
    var onTick: ((Double) -> Void)?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL?) {
        unload()
        guard let url, FileManager.default.fileExists(atPath: url.path),
            let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0
        else { return }
        player.enableRate = true
        player.rate = rate
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        available = true
    }

    func unload() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        available = false
        isPlaying = false
        started = false
        time = 0
        duration = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.rate = rate
        guard player.play() else { return }
        isPlaying = true
        started = true
        startTimer()
        tick()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
        tick()
    }

    func play(from seconds: Double) {
        seek(to: seconds)
        play()
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        started = true
        tick()
    }

    func skip(_ seconds: Double) { seek(to: (player?.currentTime ?? 0) + seconds) }

    func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        time = player?.currentTime ?? 0
        onTick?(time)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.timer?.invalidate()
            self.timer = nil
            self.time = self.duration
            self.onTick?(self.time)
        }
    }
}

extension CallDocument {
    /// audio.m4a, if "Save raw audio" was on for this call.
    var audioURL: URL? {
        let url = folder.appendingPathComponent("audio.m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
