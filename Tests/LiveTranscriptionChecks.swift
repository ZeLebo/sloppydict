import Foundation

private enum CheckError: Error { case recognition }

private actor ModelStub {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maxActive = 0
    private var blocked: Bool
    private let fails: Bool
    private let text: String
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blocked: Bool = false, fails: Bool = false, text: String = "draft") {
        self.blocked = blocked
        self.fails = fails
        self.text = text
    }

    func recognize(_ samples: [Float]) async throws -> String {
        precondition(samples.count == 32_000)
        calls += 1
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        if fails { throw CheckError.recognition }
        return text
    }

    func release() {
        blocked = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@main
struct LiveTranscriptionChecks {
    @MainActor
    static func main() async {
        await minimumAudioThenUpdates()
        await stopDrainsWithoutPublishing()
        await restartCannotOverlapOldRecognition()
        await errorIsReportedOnce()
        await silenceAndEmptyResultsDoNotPublish()
        print("5 isolated live transcription checks passed. No microphone, models, windows or clipboard used.")
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("Timed out waiting for an isolated recognition task")
    }

    @MainActor
    private static func minimumAudioThenUpdates() async {
        let worker = LiveTranscription(interval: .milliseconds(1))
        let model = ModelStub()
        var enough = false
        var snapshots = 0
        var updates: [String] = []
        worker.start(snapshot: {
            snapshots += 1
            return Array(repeating: 0.1, count: enough ? 32_000 : 31_999)
        }, transcribe: { try await model.recognize($0) }, update: {
            if case .success(let text) = $0 { updates.append(text) }
        })
        await waitUntil { snapshots > 2 }
        let before = await model.calls
        precondition(before == 0 && updates.isEmpty)
        enough = true
        await waitUntil { !updates.isEmpty }
        await worker.stop()?.value
        let maxActive = await model.maxActive
        precondition(updates.allSatisfy { $0 == "draft" } && maxActive == 1)
    }

    @MainActor
    private static func stopDrainsWithoutPublishing() async {
        let worker = LiveTranscription(interval: .milliseconds(1))
        let model = ModelStub(blocked: true)
        var updates = 0
        worker.start(snapshot: { Array(repeating: 0.1, count: 32_000) },
                     transcribe: { try await model.recognize($0) }, update: { _ in updates += 1 })
        await waitUntil { await model.calls == 1 }
        let pending = worker.stop()
        var drained = false
        let finish = Task { await pending?.value; drained = true }
        try? await Task.sleep(for: .milliseconds(10))
        precondition(!drained && updates == 0, "Final ASR must wait for the cancelled preview")
        await model.release()
        await finish.value
        let active = await model.active
        precondition(drained && updates == 0 && active == 0)
    }

    @MainActor
    private static func restartCannotOverlapOldRecognition() async {
        let worker = LiveTranscription(interval: .milliseconds(1))
        let model = ModelStub(blocked: true)
        var updates: [String] = []
        worker.start(snapshot: { Array(repeating: 0.1, count: 32_000) },
                     transcribe: { try await model.recognize($0) }, update: { _ in updates.append("old") })
        await waitUntil { await model.calls == 1 }
        worker.start(snapshot: { Array(repeating: 0.1, count: 32_000) },
                     transcribe: { try await model.recognize($0) }, update: { _ in updates.append("new") })
        try? await Task.sleep(for: .milliseconds(10))
        let beforeRelease = await model.calls
        precondition(beforeRelease == 1)
        await model.release()
        await waitUntil { !updates.isEmpty }
        await worker.stop()?.value
        let maxActive = await model.maxActive
        precondition(maxActive == 1 && updates.allSatisfy { $0 == "new" })
    }

    @MainActor
    private static func errorIsReportedOnce() async {
        let worker = LiveTranscription(interval: .milliseconds(1))
        let model = ModelStub(fails: true)
        var failures = 0
        worker.start(snapshot: { Array(repeating: 0.1, count: 32_000) },
                     transcribe: { try await model.recognize($0) }, update: {
            if case .failure = $0 { failures += 1 }
        })
        await waitUntil { failures == 1 }
        try? await Task.sleep(for: .milliseconds(10))
        await worker.stop()?.value
        let calls = await model.calls
        precondition(calls == 1 && failures == 1)
    }

    @MainActor
    private static func silenceAndEmptyResultsDoNotPublish() async {
        let worker = LiveTranscription(interval: .milliseconds(1))
        let model = ModelStub(text: "")
        var sample: Float = 0
        var snapshots = 0
        var updates = 0
        worker.start(snapshot: {
            snapshots += 1
            return Array(repeating: sample, count: 32_000)
        }, transcribe: { try await model.recognize($0) }, update: { _ in updates += 1 })
        await waitUntil { snapshots > 2 }
        let silentCalls = await model.calls
        precondition(silentCalls == 0)
        sample = .infinity
        snapshots = 0
        await waitUntil { snapshots > 2 }
        let invalidCalls = await model.calls
        precondition(invalidCalls == 0)
        sample = 0.1
        await waitUntil { await model.calls > 0 }
        await worker.stop()?.value
        precondition(updates == 0)
    }
}
