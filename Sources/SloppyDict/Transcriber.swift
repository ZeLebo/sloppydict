import CoreML
import FluidAudio
import Foundation

actor Transcriber {
    private var manager: AsrManager?

    static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SloppyDict/Models", isDirectory: true)
            .appendingPathComponent(Repo.parakeetUltra.folderName, isDirectory: true)
    }

    static func isDownloaded(at directory: URL = modelDirectory) -> Bool {
        AsrModels.modelsExist(at: directory, version: .ultra)
    }

    func load(
        at directory: URL = modelDirectory,
        download: Bool,
        progress: ProgressHandler? = nil
    ) async throws {
        guard manager == nil else { return }
        ModelRegistry.revisionOverrides = [
            "FluidInference/parakeet-ultra-coreml": "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
        ]
        ModelHub.offlineMode = !download
        defer { ModelHub.offlineMode = true }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        if download {
            // Download the complete pinned repository, including its vocabulary, before offline loading.
            try await ModelHub.download(
                .parakeetUltra, to: directory.deletingLastPathComponent(), progressHandler: progress
            )
        }
        ModelHub.offlineMode = true
        let models = try await AsrModels.load(
            from: directory, configuration: configuration, version: .ultra,
            encoderComputeUnits: .cpuAndNeuralEngine, progressHandler: progress
        )
        try Task.checkCancellation()
        let recognizer = AsrManager()
        try await recognizer.loadModels(models)
        manager = recognizer
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let manager else { throw DictationError.message("Сначала загрузите модель.") }
        try Task.checkCancellation()
        var state = try TdtDecoderState()
        let hint: Language? = language == "ru" ? .russian : (language == "en" ? .english : nil)
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(file: URL) async throws -> String {
        guard let manager else { throw DictationError.message("Модель не загружена.") }
        var state = try TdtDecoderState()
        return try await manager.transcribe(file, decoderState: &state).text
    }
}
