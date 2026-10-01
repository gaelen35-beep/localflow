import FluidAudio
import Foundation

/// Parakeet TDT via FluidAudio (Core ML / Neural Engine). Models are cached after the first download.
actor Transcriber {
    private var manager: AsrManager?

    var isReady: Bool { manager != nil }

    /// Drops the model so its memory can be reclaimed while LocalFlow is switched off.
    func unload() { manager = nil }

    func load() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        // Warm-up so the first real dictation doesn't pay for Core ML specialisation.
        if var state = try? TdtDecoderState() {
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16000), decoderState: &state)
        }
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else {
            throw NSError(domain: "LocalFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model not loaded yet"])
        }
        // Parakeet wants at least ~1s of audio; pad short clips with silence.
        var audio = samples
        if audio.count < 16000 { audio += [Float](repeating: 0, count: 16000 - audio.count) }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
