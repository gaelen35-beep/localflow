@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures 16 kHz mono Float32 samples from the default input device.
/// A fresh engine is built on every start so device changes (AirPods, etc.) are picked up.
final class AudioRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var currentLevel: Float = 0

    /// UID of the microphone to use; nil means the system default input.
    var preferredDeviceUID: String?

    /// Loudness of the most recent audio buffer, 0...1 (perceptually scaled). Drives the overlay waveform.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return currentLevel
    }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); currentLevel = 0; lock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = preferredDeviceUID, var deviceID = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.write("could not select microphone \(uid): OSStatus \(status)") }
        } else if let uid = preferredDeviceUID {
            Log.write("selected microphone \(uid) not connected; using system default")
        }
        let inFormat = input.outputFormat(forBus: 0)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "LocalFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio converter for input format"])
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [self] buffer, _ in
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var consumed = false
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
        self.engine = engine
        Log.write("recording from \(preferredDeviceUID ?? "system default input") at \(Int(inFormat.sampleRate)) Hz")
    }

    private func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
        let meanSquare = chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(chunk.count, 1))
        currentLevel = min(1, meanSquare.squareRoot().squareRoot() * 2.2)
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}
