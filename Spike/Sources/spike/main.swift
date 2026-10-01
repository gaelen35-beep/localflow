@preconcurrency import AVFoundation
import FluidAudio
import Foundation

// Phase 0 spike: transcribe a file, or record N seconds from the mic, with Parakeet via FluidAudio.
// Usage: spike [seconds]        record from mic (default 5s)
//        spike path/to/audio    transcribe a file

/// Collects 16 kHz mono Float32 samples from the default input device.
final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inFormat, to: outFormat)!

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [self] buffer, _ in
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var consumed = false
            converter.convert(to: out, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard let ch = out.floatChannelData?[0] else { return }
            append(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        }
        try engine.start()
    }

    private func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
    }

    func stop() -> [Float] {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

let arg = CommandLine.arguments.dropFirst().first
let clock = ContinuousClock()

let loadStart = clock.now
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asr = AsrManager(config: .default)
try await asr.loadModels(models)
print("Model load: \(loadStart.duration(to: clock.now))")

if let arg, FileManager.default.fileExists(atPath: arg) {
    var state = try TdtDecoderState()
    let t = clock.now
    let result = try await asr.transcribe(URL(fileURLWithPath: arg), decoderState: &state)
    print("Transcribe: \(t.duration(to: clock.now))\n\(result.text)")
} else {
    let seconds = Double(arg ?? "5") ?? 5
    let recorder = MicRecorder()
    try recorder.start()
    print("Recording \(Int(seconds))s... speak now")
    try await Task.sleep(for: .seconds(seconds))
    let samples = recorder.stop()
    print("Captured \(samples.count) samples (\(Double(samples.count) / 16000)s)")

    // Warm-up pass so the timing below reflects steady state, not first-run compilation.
    var warm = try TdtDecoderState()
    _ = try await asr.transcribe(samples, decoderState: &warm)

    var state = try TdtDecoderState()
    let t = clock.now
    let result = try await asr.transcribe(samples, decoderState: &state)
    print("Transcribe (warm): \(t.duration(to: clock.now))\n\(result.text)")
}
