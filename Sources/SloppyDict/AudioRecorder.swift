import AVFoundation
import Foundation

@MainActor
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var accumulator: AudioAccumulator?

    func start(onLimit: @escaping @Sendable () -> Void, onError: @escaping @Sendable (String) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw DictationError.message("Микрофон недоступен или его формат не поддерживается.")
        }
        let accumulator = AudioAccumulator(converter: converter, format: output, onLimit: onLimit, onError: onError)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            accumulator.append(buffer)
        }
        self.engine = engine
        self.accumulator = accumulator
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    @discardableResult
    func stop() -> [Float] {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        let samples = accumulator?.finish() ?? []
        accumulator = nil
        return samples
    }
}

// AVAudioConverter is used only inside the tap; the lock also protects stop's snapshot.
private final class AudioAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let onLimit: @Sendable () -> Void
    private let onError: @Sendable (String) -> Void
    private var samples: [Float] = []
    private var finished = false
    private static let limit = 16_000 * 120

    init(converter: AVAudioConverter, format: AVAudioFormat,
         onLimit: @escaping @Sendable () -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.converter = converter
        self.format = format
        self.onLimit = onLimit
        self.onError = onError
        samples.reserveCapacity(Self.limit)
    }

    func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            finished = true
            lock.unlock()
            onError("Не удалось выделить аудиобуфер.")
            return
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error {
            finished = true
            lock.unlock()
            onError(error.localizedDescription)
            return
        }
        if let channel = output.floatChannelData?[0] {
            let count = min(Int(output.frameLength), Self.limit - samples.count)
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
        let reachedLimit = samples.count >= Self.limit
        if reachedLimit { finished = true }
        lock.unlock()
        if reachedLimit { onLimit() }
    }

    func finish() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        let result = samples
        samples = []
        return result
    }
}
