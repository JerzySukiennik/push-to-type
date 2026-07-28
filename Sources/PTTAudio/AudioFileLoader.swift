import AVFoundation
import Foundation
import PTTSupport

/// Reads an audio file as the 16 kHz mono float samples whisper expects.
///
/// The app itself never reads files — it records. This exists for the diagnostics tool and
/// the test suite, which both need a deterministic input to prove the inference path works
/// without a human speaking into a microphone. It lives here rather than being copied into
/// each, and it shares the recorder's conversion approach so the two cannot drift.
public enum AudioFileLoader {

    /// Decodes and resamples `url` to 16 kHz mono.
    ///
    /// - Throws: ``PTTError/audioEngineFailed(reason:)`` for anything the system cannot
    ///   decode, or the underlying `AVFoundation` error.
    public static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: WhisperSampleRate.value,
            channels: 1,
            interleaved: false
        ) else {
            throw PTTError.audioEngineFailed(reason: "could not create the 16 kHz format")
        }

        guard
            let converter = AVAudioConverter(from: file.processingFormat, to: target),
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw PTTError.audioEngineFailed(
                reason: "unsupported audio format in \(url.lastPathComponent)"
            )
        }

        try file.read(into: input)

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        ) else {
            throw PTTError.audioEngineFailed(reason: "could not allocate the output buffer")
        }

        let pending = CallLocal(input)
        let delivered = CallLocal(false)
        var conversionError: NSError?

        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if delivered.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered.value = true
            outStatus.pointee = .haveData
            return pending.value
        }

        if let conversionError { throw conversionError }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw PTTError.audioEngineFailed(reason: "conversion failed")
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
