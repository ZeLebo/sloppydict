import Foundation

@MainActor
final class LiveTranscription {
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(interval: Duration = .seconds(1)) { self.interval = interval }

    func start(
        snapshot: @escaping @MainActor () -> [Float],
        transcribe: @escaping @Sendable ([Float]) async throws -> String,
        update: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        let previous = stop()
        let interval = interval
        task = Task {
            await previous?.value
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    let samples = snapshot()
                    guard samples.count >= 32_000,
                          samples.allSatisfy(\.isFinite),
                          samples.contains(where: { abs($0) > 0.0001 }) else { continue }
                    let text = try await transcribe(samples)
                    try Task.checkCancellation()
                    if !text.isEmpty { update(.success(text)) }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { update(.failure(error)) }
            }
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        let previous = task
        task = nil
        previous?.cancel()
        // Callers await this before final ASR so both passes never use the model together.
        return previous
    }
}
