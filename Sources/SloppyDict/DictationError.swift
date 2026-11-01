import Foundation

enum DictationError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
