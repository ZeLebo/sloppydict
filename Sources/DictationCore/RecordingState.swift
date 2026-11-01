import Foundation

public enum RecordingMode: String, Sendable {
    case hold, toggle
}

public enum RecordingPhase: Equatable, Sendable {
    case idle
    case recording(RecordingMode)
    case transcribing
}

public enum RecordingEffect: Equatable, Sendable {
    case start, finish, cancel
}

public struct RecordingState: Sendable {
    public private(set) var phase: RecordingPhase = .idle

    public init() {}

    public mutating func press(_ mode: RecordingMode) -> RecordingEffect? {
        switch phase {
        case .idle:
            phase = .recording(mode)
            return .start
        case .recording(.toggle) where mode == .toggle:
            phase = .transcribing
            return .finish
        default:
            return nil
        }
    }

    public mutating func release(_ mode: RecordingMode) -> RecordingEffect? {
        guard mode == .hold, phase == .recording(.hold) else { return nil }
        phase = .transcribing
        return .finish
    }

    public mutating func cancel() -> RecordingEffect? {
        guard phase != .idle else { return nil }
        phase = .idle
        return .cancel
    }

    public mutating func finish() -> RecordingEffect? {
        guard case .recording = phase else { return nil }
        phase = .transcribing
        return .finish
    }

    public mutating func complete() {
        phase = .idle
    }
}
