import AVFoundation
import EarshotCore
import FluidAudio
import Foundation

// earshot-cli: headless twin of the app, used by setup.sh and for end-to-end tests.
//
//   earshot-cli models                      download + warm every model
//   earshot-cli devices                     list audio devices
//   earshot-cli live [--seconds N]          record the real microphone + system audio
//   earshot-cli simulate --them a.wav [--me b.wav]   feed files through the live pipeline in real time
//   earshot-cli summarize <call-folder> [--instructions TEXT]   (re)generate summary.md

setvbuf(stdout, nil, _IOLBF, 0)

struct Arguments {
    var command: String
    var flags: [String: String] = [:]
    var switches: Set<String> = []
    var positional: [String] = []

    init(_ raw: [String]) {
        command = raw.first ?? "help"
        var index = 1
        while index < raw.count {
            let item = raw[index]
            if item.hasPrefix("--") {
                let key = String(item.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    flags[key] = raw[index + 1]
                    index += 1
                } else {
                    switches.insert(key)
                }
            } else {
                positional.append(item)
            }
            index += 1
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func loadModels(_ arguments: Arguments) async -> SpeechModels {
    let options = SpeechModelOptions(
        asr: AsrModelChoice(rawValue: arguments.flags["asr"] ?? "ultra") ?? .ultra,
        diarization: !arguments.switches.contains("no-diarization"),
        echoCancellation: !arguments.switches.contains("no-aec"))
    let began = Date()
    do {
        let models = try await SpeechModels.load(options) { print("· \($0)") }
        print(String(format: "· models ready in %.1f s", Date().timeIntervalSince(began)))
        return models
    } catch {
        fail("could not load speech models: \(error.localizedDescription)")
    }
}

func runSession(
    _ arguments: Arguments, models: SpeechModels, microphone: CaptureSource?, system: CaptureSource?, seconds: Double,
    systemChoice: SystemAudioChoice
) async {
    let title = arguments.flags["title"] ?? "Call"
    let root = arguments.flags["root"].map { URL(fileURLWithPath: $0) } ?? CallFolder.defaultRoot
    let config = SessionConfig(
        title: title, titleIsPlaceholder: arguments.flags["title"] == nil, root: root, systemAudio: systemChoice,
        captureMicrophone: !arguments.switches.contains("no-mic"), microphoneUID: arguments.flags["mic"],
        saveAudio: arguments.switches.contains("save-audio"),
        echoTextGuard: !arguments.switches.contains("no-echo-guard"))
    let began = Date()
    let showPartials = arguments.switches.contains("partials")
    @Sendable func clock() -> String { String(format: "%6.2f", Date().timeIntervalSince(began)) }

    let session = CallSession(config: config, models: models, microphone: microphone, system: system) { event in
        switch event {
        case .segment(let segment):
            let who = segment.channel == .me ? "Me" : "Them" + (segment.speaker.map { " \($0)" } ?? "")
            print("[\(clock())] FINAL \(TranscriptFormat.timestamp(segment.start))–\(TranscriptFormat.timestamp(segment.end)) \(who): \(segment.text)")
        case .partial(let channel, let text, _):
            if showPartials, let text { print("[\(clock())]   … \(channel == .me ? "Me" : "Them"): \(text)") }
        case .warning(let message):
            print("[\(clock())] WARNING \(message)")
        case .level:
            break
        }
    }

    do { try await session.start() } catch { fail("could not start: \(error.localizedDescription)") }
    print("· recording for \(Int(seconds)) s → \(await session.folderURL?.path ?? "?")")
    scheduleMarkers(arguments, session: session)
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    guard var result = await session.stop() else { fail("session produced no result") }

    print("\n== Call saved: \(result.folder.transcriptURL.path)")
    print(String(format: "   duration %.1f s, %d lines, remote speakers: %d", result.duration, result.segments.count, result.remoteSpeakers))
    for channel in ["me", "them"] {
        if let words = result.metrics.wordLatency[channel], words.count > 0 {
            print(String(format: "   %@ word→screen latency: mean %.2f s, p50 %.2f s, p95 %.2f s, max %.2f s (%d words)",
                channel, words.mean, words.p50, words.p95, words.max, words.count))
        }
        if let commits = result.metrics.commitLatency[channel], commits.count > 0 {
            print(String(format: "   %@ utterance-end→committed line: mean %.2f s, p95 %.2f s (%d lines)",
                channel, commits.mean, commits.p95, commits.count))
        }
        if let factor = result.metrics.asrRealTimeFactor[channel] {
            print(String(format: "   %@ ASR speed: %.0f× real time", channel, factor))
        }
    }
    print("   echo lines dropped: \(result.metrics.echoLinesDropped)")
    if let path = arguments.flags["metrics"], let data = try? JSONEncoder().encode(result.metrics) {
        try? data.write(to: URL(fileURLWithPath: path))
    }

    guard !arguments.switches.contains("no-summary") else { return }
    let model = arguments.flags["model"] ?? Summarizer.defaultModel
    do {
        let summary = try await CallSummary.write(
            for: &result, model: model, instructions: arguments.flags["instructions"] ?? ""
        ) { print("· \($0)") }
        print(String(format: "== Summary (%@, %.1f s, %d chunk(s)): %@", summary.model, summary.seconds, summary.chunks, result.folder.summaryURL.path))
    } catch {
        CallSummary.writeFailure(folder: result.folder.url, title: result.title, error: error)
        print("== Summary failed: \(error.localizedDescription)")
    }
}

/// `--pause 10-20` (call seconds, several separated by commas), `--mark 5,12` and
/// `--note "8=Ask about pricing"`: exercise notes, marks and off-the-record pauses in tests.
func scheduleMarkers(_ arguments: Arguments, session: CallSession) {
    func at(_ seconds: Double, _ action: @escaping @Sendable () async -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
            await action()
        }
    }
    for span in (arguments.flags["pause"] ?? "").split(separator: ",") {
        let bounds = span.split(separator: "-").compactMap { Double($0) }
        guard bounds.count == 2, bounds[1] > bounds[0] else { fail("--pause needs START-END in seconds") }
        at(bounds[0]) {
            await session.setPaused(true)
            print("· paused at \(bounds[0]) s")
        }
        at(bounds[1]) {
            await session.setPaused(false)
            print("· resumed at \(bounds[1]) s")
        }
    }
    for time in (arguments.flags["mark"] ?? "").split(separator: ",").compactMap({ Double($0) }) {
        at(time) { await session.addNote("") }
    }
    if let note = arguments.flags["note"], let equals = note.firstIndex(of: "="), let time = Double(note[..<equals]) {
        let text = String(note[note.index(after: equals)...])
        at(time) { await session.addNote(text) }
    }
}

func saveWAV(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

func loadAudio(_ path: String) -> [Float] {
    do { return try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path)) } catch {
        fail("could not read \(path): \(error.localizedDescription)")
    }
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

switch arguments.command {
case "models":
    _ = await loadModels(arguments)
    print("All speech models are downloaded and compiled.")

case "devices":
    print("Default input:  \(AudioDevices.defaultInput()?.name ?? "none")")
    print("Default output: \(AudioDevices.defaultOutput()?.name ?? "none")")
    print("BlackHole:      \(AudioDevices.blackHole()?.name ?? "not installed")")
    for device in AudioDevices.all() {
        print("  [\(device.inputChannels) in / \(device.outputChannels) out] \(device.name)  uid=\(device.uid)")
    }

case "live":
    let seconds = Double(arguments.flags["seconds"] ?? "30") ?? 30
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
    var choice = SystemAudioChoice.tap
    if arguments.switches.contains("blackhole") {
        guard let device = AudioDevices.blackHole() else { fail("BlackHole is not installed") }
        choice = .device(uid: device.uid)
    } else if arguments.switches.contains("no-system") {
        choice = .none
    }
    let models = await loadModels(arguments)
    await runSession(arguments, models: models, microphone: nil, system: nil, seconds: seconds, systemChoice: choice)

case "simulate":
    guard let themPath = arguments.flags["them"] else { fail("simulate needs --them <audio file>") }
    let them = loadAudio(themPath)
    let me = arguments.flags["me"].map(loadAudio)
    let models = await loadModels(arguments)
    let themSource = FileAudioSource(samples: them, label: "them-file")
    let meSource = me.map { FileAudioSource(samples: $0, label: "me-file") }
    let tail = Double(arguments.flags["tail"] ?? "2.5") ?? 2.5
    let seconds = max(themSource.duration, meSource?.duration ?? 0) + tail
    await runSession(arguments, models: models, microphone: meSource, system: themSource, seconds: seconds, systemChoice: .none)

case "aec":
    // Diagnostic: run the echo canceller over a mic/reference pair and write the cleaned audio.
    guard let micPath = arguments.flags["mic"], let referencePath = arguments.flags["ref"],
        let outPath = arguments.flags["out"]
    else { fail("aec needs --mic FILE --ref FILE --out FILE") }
    let mic = loadAudio(micPath)
    var reference = loadAudio(referencePath)
    reference = Array(reference.prefix(mic.count)) + [Float](repeating: 0, count: max(0, mic.count - reference.count))
    do {
        let chunk: LocalVqeChunk = arguments.switches.contains("realtime") ? .realtime16ms : .batch256ms
        let manager = try await LocalVqeManager(config: LocalVqeConfig(chunk: chunk))
        let began = Date()
        let stream = try await manager.makeStream()
        var cleaned: [Float] = []
        let step = 512
        var index = 0
        while index < mic.count {
            let end = min(index + step, mic.count)
            cleaned += try await stream.enhance(mic: Array(mic[index..<end]), reference: Array(reference[index..<end]))
            index = end
        }
        cleaned += try await stream.flush()
        print(String(format: "echo cancellation: %.1f s of audio in %.2f s", Double(mic.count) / 16000, Date().timeIntervalSince(began)))
        try saveWAV(cleaned, to: URL(fileURLWithPath: outPath))
    } catch {
        fail(error.localizedDescription)
    }

case "play":
    // Test helper: opens the output device immediately (so the process is known to Core Audio),
    // waits for the --when file to appear, then plays the audio file through the default output.
    guard let path = arguments.positional.first else { fail("play needs an audio file") }
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        try engine.start()
        player.play()
        print("player ready pid=\(getpid())")
        if let gate = arguments.flags["when"] {
            while !FileManager.default.fileExists(atPath: gate) { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        print("player started")
        player.scheduleFile(file, at: nil, completionHandler: nil)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        try await Task.sleep(nanoseconds: UInt64((seconds + 0.5) * 1e9))
        engine.stop()
    } catch {
        fail(error.localizedDescription)
    }

case "transcribe":
    // Benchmark helper: offline (batch) transcription of one file with the selected Parakeet model.
    guard let path = arguments.positional.first else { fail("transcribe needs an audio file") }
    let audio = loadAudio(path)
    do {
        let version: AsrModelVersion = arguments.flags["asr"] == "v2" ? .v2 : arguments.flags["asr"] == "v3" ? .v3 : .ultra
        let manager = AsrManager(config: .default)
        try await manager.loadModels(try await AsrModels.downloadAndLoad(version: version))
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe([Float](repeating: 0, count: 32000), decoderState: &state)
        let began = Date()
        state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        let seconds = Date().timeIntervalSince(began)
        let duration = Double(audio.count) / 16000
        FileHandle.standardError.write(Data(String(format: "%.1f s of audio in %.2f s = %.0fx real time\n", duration, seconds, duration / seconds).utf8))
        print(result.text)
    } catch {
        fail(error.localizedDescription)
    }

case "summarize":
    guard let folder = arguments.positional.first else { fail("summarize needs a call folder") }
    let model = arguments.flags["model"] ?? Summarizer.defaultModel
    do {
        let summary = try await CallSummary.regenerate(
            folder: URL(fileURLWithPath: folder), model: model, instructions: arguments.flags["instructions"] ?? ""
        ) { print("· \($0)") }
        print(String(format: "Summary written with %@ in %.1f s (%d chunk(s)).", summary.model, summary.seconds, summary.chunks))
    } catch {
        fail(error.localizedDescription)
    }

default:
    print("""
        usage: earshot-cli <command>
          models                                  download and warm the speech models
          devices                                 list audio devices
          live [--seconds N] [--title T] [--blackhole | --no-system] [--no-mic] [--save-audio]
          simulate --them FILE [--me FILE] [--title T] [--partials]
          summarize <call-folder> [--model NAME] [--instructions TEXT]
        live / simulate: --pause START-END[,…]  --mark SECONDS[,…]  --note "SECONDS=text"  (seconds into the call)
        common: --asr ultra|v3|v2  --model <ollama model>  --no-summary  --no-aec  --no-diarization
                --no-echo-guard  --root <calls dir>  --metrics <json file>  --instructions <extra summary guidance>
        """)
}
