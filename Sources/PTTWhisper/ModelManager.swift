import Foundation
import PTTSettings
import PTTSupport

/// Owns the model files on disk: what is present, what is downloading, what to delete.
///
/// Kept separate from ``WhisperEngine`` because the two have different lifetimes and
/// different failure modes — the engine cares about a loaded context, this cares about
/// bytes on a volume — and because the menu bar needs to ask "is the model there?"
/// without touching inference at all.
public actor ModelManager {

    /// Progress of an in-flight download, 0…1.
    public typealias ProgressHandler = @Sendable (Double) -> Void

    /// Deduplicates concurrent requests for the same model: two menu clicks start one
    /// download, and both callers await the same result.
    private var inFlight: [WhisperModel: Task<URL, Error>] = [:]
    private var downloaders: [WhisperModel: ModelDownloader] = [:]

    public init() {}

    // MARK: - Queries

    /// Models that are fully present on disk.
    public func downloadedModels() -> [WhisperModel] {
        WhisperModel.allCases.filter(\.isDownloaded)
    }

    /// `true` while `model` is being fetched.
    public func isDownloading(_ model: WhisperModel) -> Bool {
        inFlight[model] != nil
    }

    // MARK: - Acquisition

    /// Returns the on-disk URL for `model`, downloading it first if necessary.
    ///
    /// This is the single entry point used by the dictation flow: it turns "the user
    /// pressed the key and the model may or may not exist" into either a usable file or a
    /// typed error, with no intermediate states for the caller to handle.
    public func ensureAvailable(
        _ model: WhisperModel,
        progress: ProgressHandler? = nil
    ) async throws -> URL {
        if model.isDownloaded { return model.fileURL }
        return try await download(model, progress: progress)
    }

    /// Downloads `model`, replacing any existing file.
    ///
    /// The file is written to scratch space, size-checked, and only then moved into the
    /// models directory — so an interrupted download can never leave something that
    /// `isDownloaded` would report as usable.
    @discardableResult
    public func download(
        _ model: WhisperModel,
        progress: ProgressHandler? = nil
    ) async throws -> URL {
        if let existing = inFlight[model] {
            return try await existing.value
        }

        let downloader = ModelDownloader()
        downloaders[model] = downloader

        let task = Task<URL, Error> { [downloader] in
            let temporary = try await downloader.download(
                from: model.downloadURL,
                expectedBytes: model.fileSize,
                progress: { progress?($0) }
            )

            do {
                try Self.verify(temporary, against: model)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }

            try AppPaths.ensureDirectory(AppPaths.models)
            let destination = model.fileURL
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)

            Log.whisper.info("Downloaded \(model.rawValue, privacy: .public)")
            return destination
        }

        inFlight[model] = task
        defer {
            inFlight[model] = nil
            downloaders[model] = nil
        }

        do {
            return try await task.value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PTTError {
            throw error
        } catch {
            throw PTTError.modelDownloadFailed(
                name: model.displayName,
                reason: error.localizedDescription
            )
        }
    }

    /// Rejects anything that is not byte-for-byte the published model file.
    ///
    /// Both failures this catches were observed while building the app: a download that
    /// stopped early, and a mirror that answered `401` with a 29-byte body. Publishing
    /// either into the models directory would surface much later as an opaque failure
    /// inside whisper.cpp's loader.
    private static func verify(_ url: URL, against model: WhisperModel) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size == model.fileSize else {
            throw PTTError.modelDownloadFailed(
                name: model.displayName,
                reason: "expected \(model.fileSize) bytes but received \(size)"
            )
        }

        guard WhisperModel.hasGGMLHeader(at: url) else {
            throw PTTError.modelDownloadFailed(
                name: model.displayName,
                reason: "the downloaded file is not a GGML model"
            )
        }
    }

    /// Stops an in-flight download and discards its partial file.
    public func cancelDownload(_ model: WhisperModel) {
        downloaders[model]?.cancel()
        inFlight[model]?.cancel()
        inFlight[model] = nil
        downloaders[model] = nil
    }

    /// Deletes a downloaded model to reclaim disk space.
    public func delete(_ model: WhisperModel) throws {
        guard FileManager.default.fileExists(atPath: model.fileURL.path) else { return }
        try FileManager.default.removeItem(at: model.fileURL)
        Log.whisper.info("Deleted \(model.rawValue, privacy: .public)")
    }

    /// Removes leftovers from downloads interrupted by a quit or a crash.
    ///
    /// Called once, off the launch path, rather than by a timer.
    public func cleanUpScratchFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.downloads,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in contents where file.pathExtension == "partial" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
