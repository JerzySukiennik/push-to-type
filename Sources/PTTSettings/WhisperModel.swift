import Foundation
import PTTSupport

/// The GGML models PushToType offers.
///
/// The catalog is deliberately short: anything larger than `small` is slower than
/// real time on the CPU-only path, which defeats the point of push-to-talk. English-only
/// variants (`.en`) are both faster and more accurate for English, so they are the
/// default; the multilingual variants unlock the language picker.
public enum WhisperModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case tinyEn = "tiny.en"
    case tiny = "tiny"
    case baseEn = "base.en"
    case base = "base"
    case smallEn = "small.en"
    case small = "small"

    public var id: String { rawValue }

    /// The default for a fresh install: the best accuracy/latency trade-off on CPU.
    public static let `default`: WhisperModel = .baseEn

    /// File name on disk and inside the Hugging Face repository.
    public var fileName: String { "ggml-\(rawValue).bin" }

    /// Where the file lives once downloaded.
    public var fileURL: URL { AppPaths.models.appendingPathComponent(fileName) }

    /// Official whisper.cpp model mirror. Plain HTTPS, no token, no API.
    ///
    /// The repository is `ggerganov/whisper.cpp`, not the `ggml-org` organisation that now
    /// hosts the source: the models never moved, and the `ggml-org` path answers 401.
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    /// Exact size of the published file, in bytes.
    ///
    /// Exact rather than approximate on purpose. A "roughly the right size" check accepts
    /// both a truncated download and a file that two writers appended to — this project hit
    /// both while being built. An equality check plus the magic number in ``isDownloaded``
    /// rejects them.
    public var fileSize: Int64 {
        switch self {
        case .tinyEn: 77_704_715
        case .tiny: 77_691_713
        case .baseEn: 147_964_211
        case .base: 147_951_465
        case .smallEn: 487_614_201
        case .small: 487_601_967
        }
    }

    /// `true` for models that only ever produce English.
    public var isEnglishOnly: Bool {
        switch self {
        case .tinyEn, .baseEn, .smallEn: true
        case .tiny, .base, .small: false
        }
    }

    public var displayName: String {
        switch self {
        case .tinyEn: "Tiny (English)"
        case .tiny: "Tiny (multilingual)"
        case .baseEn: "Base (English)"
        case .base: "Base (multilingual)"
        case .smallEn: "Small (English)"
        case .small: "Small (multilingual)"
        }
    }

    /// One-line hint shown next to the name in the model menu.
    public var subtitle: String {
        switch self {
        case .tinyEn, .tiny: "Fastest, least accurate · 75 MB"
        case .baseEn, .base: "Recommended · 141 MB"
        case .smallEn, .small: "Most accurate, noticeably slower · 465 MB"
        }
    }

    /// Human-readable size for menus.
    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// The GGML container magic as it appears on disk.
    ///
    /// whisper.cpp writes the constant `0x67676D6C` ("ggml") as a little-endian `uint32`,
    /// so the first four bytes of the file read `6C 6D 67 67` — the string backwards. The
    /// obvious byte order is the wrong one here.
    public static let ggmlMagic: [UInt8] = [0x6C, 0x6D, 0x67, 0x67]

    /// `true` when the file at `url` starts with the GGML magic.
    public static func hasGGMLHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else {
            return false
        }
        return Array(header) == ggmlMagic
    }

    /// `true` when a complete, plausible model file is on disk.
    ///
    /// Two cheap checks, both earned the hard way: the exact size rejects truncated and
    /// double-appended downloads, and the magic number rejects the HTML error page a
    /// mirror hands out when a URL goes stale. Without them whisper.cpp fails somewhere
    /// deep inside its loader with an unhelpful message.
    public var isDownloaded: Bool {
        guard
            let size = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int64,
            size == fileSize
        else { return false }
        return hasValidHeader
    }

    /// `true` when the file on disk carries a GGML header.
    public var hasValidHeader: Bool {
        Self.hasGGMLHeader(at: fileURL)
    }

    /// The multilingual counterpart of an English-only model, and vice versa.
    /// Used when the user picks a non-English language while an `.en` model is active.
    public var multilingualCounterpart: WhisperModel {
        switch self {
        case .tinyEn: .tiny
        case .baseEn: .base
        case .smallEn: .small
        default: self
        }
    }
}
