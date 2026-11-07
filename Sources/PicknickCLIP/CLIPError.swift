import Foundation

/// Failures specific to the MobileCLIP encoders.
///
/// Kept separate from `PicknickError` so search can tell "the model is not
/// installed" (degrade to labels and text) apart from a one-off prediction
/// failure on a single image.
public enum CLIPError: Error, Sendable, Hashable {
    case modelMissing(URL)
    case modelInvalid(URL, message: String)
    case vocabularyMissing(URL)
    case vocabularyInvalid(URL, message: String)
    /// The model loaded but its inputs or outputs are not shaped like a CLIP encoder.
    case unsupportedModelInterface(String)
    case predictionFailed(String)

    /// True when the encoder cannot run at all until the host installs or
    /// replaces a file, which is the signal to fall back to labels and text.
    public var isModelUnavailable: Bool {
        switch self {
        case .modelMissing, .modelInvalid, .vocabularyMissing, .vocabularyInvalid,
             .unsupportedModelInterface:
            true
        case .predictionFailed:
            false
        }
    }
}

extension CLIPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .modelMissing(url):
            "No CLIP model at \(url.path)."
        case let .modelInvalid(url, message):
            "CLIP model at \(url.path) could not be loaded: \(message)"
        case let .vocabularyMissing(url):
            "No CLIP BPE merges file at \(url.path)."
        case let .vocabularyInvalid(url, message):
            "CLIP BPE merges file at \(url.path) is invalid: \(message)"
        case let .unsupportedModelInterface(message):
            "CLIP model interface not supported: \(message)"
        case let .predictionFailed(message):
            "CLIP prediction failed: \(message)"
        }
    }
}
