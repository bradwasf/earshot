import CoreML
import FluidAudio
import Foundation

/// Which Parakeet build transcribes the call. All run fully on-device through Core ML.
public enum AsrModelChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Parakeet Ultra: post-trained Parakeet TDT v3. Most accurate of the family, 25 languages.
    case ultra
    /// Parakeet TDT 0.6B v3: 25 European languages.
    case v3
    /// Parakeet TDT 0.6B v2: English only.
    case v2

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ultra: return "Parakeet Ultra (most accurate, 25 languages)"
        case .v3: return "Parakeet TDT v3 (25 languages)"
        case .v2: return "Parakeet TDT v2 (English only)"
        }
    }

    var version: AsrModelVersion {
        switch self {
        case .ultra: return .ultra
        case .v3: return .v3
        case .v2: return .v2
        }
    }
}

public struct SpeechModelOptions: Sendable, Equatable {
    public var asr: AsrModelChoice
    public var diarization: Bool
    public var echoCancellation: Bool

    public init(asr: AsrModelChoice = .ultra, diarization: Bool = true, echoCancellation: Bool = true) {
        self.asr = asr
        self.diarization = diarization
        self.echoCancellation = echoCancellation
    }
}

/// The loaded Core ML models, shared by every call session.
/// Models are downloaded once (HuggingFace → ~/Library/Application Support/FluidAudio/Models) and
/// then loaded from disk; nothing is fetched at call time.
public final class SpeechModels: @unchecked Sendable {
    public let options: SpeechModelOptions
    public let asr: AsrModels
    public let vad: VadManager
    public let sortformer: SortformerModels?
    public let echoCanceller: LocalVqeManager?

    private init(
        options: SpeechModelOptions, asr: AsrModels, vad: VadManager, sortformer: SortformerModels?,
        echoCanceller: LocalVqeManager?
    ) {
        self.options = options
        self.asr = asr
        self.vad = vad
        self.sortformer = sortformer
        self.echoCanceller = echoCanceller
    }

    public static func load(
        _ options: SpeechModelOptions,
        status: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SpeechModels {
        status("Loading speech recognition model (\(options.asr.rawValue))…")
        let asr = try await AsrModels.downloadAndLoad(version: options.asr.version)

        status("Loading voice activity detector…")
        let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5))

        var sortformer: SortformerModels?
        if options.diarization {
            status("Loading speaker diarization model…")
            // Diarization is a nice-to-have: a failure here must not block transcription.
            sortformer = try? await SortformerModels.loadFromHuggingFace(config: .default)
        }

        var echoCanceller: LocalVqeManager?
        if options.echoCancellation {
            status("Loading echo canceller…")
            // 256 ms calls: ~2.5× the throughput of the 16 ms variant for ~0.1 s of extra delay.
            echoCanceller = try? await LocalVqeManager(config: LocalVqeConfig(chunk: .batch256ms))
        }

        let models = SpeechModels(
            options: options, asr: asr, vad: vad, sortformer: sortformer, echoCanceller: echoCanceller)

        // First prediction compiles the model for the Neural Engine; do it now, not mid-call.
        status("Warming up…")
        let manager = try await models.makeAsrManager()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try? await manager.transcribe([Float](repeating: 0, count: Audio.sampleRate * 2), decoderState: &state)

        status("Ready")
        return models
    }

    /// One manager per channel so the two sides of the call decode independently.
    func makeAsrManager() async throws -> AsrManager {
        let manager = AsrManager(config: .default)
        try await manager.loadModels(asr)
        return manager
    }
}
