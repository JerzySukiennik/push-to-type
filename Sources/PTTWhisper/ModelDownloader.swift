import Foundation
import PTTSupport

/// Downloads a file to disk with progress reporting and cancellation.
///
/// `URLSession`'s `async` download API reports no progress, and `AsyncBytes` yields one
/// byte at a time — unusable for a 150 MB model. So this wraps a classic
/// `URLSessionDownloadTask` with a delegate and bridges it to `async`/`await`.
///
/// The delegate methods are called on the session's own queue, so all mutable state is
/// guarded by a lock; the class is `@unchecked Sendable` for that reason and no other.
final class ModelDownloader: NSObject, @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    /// Downloads `url` and returns the location of the finished temporary file.
    ///
    /// The caller is responsible for moving that file into place; keeping the move out of
    /// here is what makes "download, verify, then publish" possible without a half-written
    /// model ever appearing in the models directory.
    ///
    /// - Throws: `URLError` for transport failures, `CancellationError` when the task is
    ///           cancelled, ``PTTError/modelDownloadFailed(name:reason:)`` for HTTP errors.
    func download(
        from url: URL,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self.progressHandler = progress
                lock.unlock()

                let configuration = URLSessionConfiguration.default
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForResource = 3600
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.downloadTask(with: url)
                task.countOfBytesClientExpectsToReceive = expectedBytes

                lock.lock()
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    /// Cancels an in-flight download. Safe to call at any time, including after finishing.
    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    /// Resumes `continuation` exactly once and tears the session down.
    private func finish(with result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.progressHandler = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        // `invalidateAndCancel` would race with the completion we are about to deliver;
        // `finishTasksAndInvalidate` lets the session retire cleanly.
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` as soon as this method returns, so the file is
        // moved to our own scratch directory synchronously, right here.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            finish(with: .failure(PTTError.modelDownloadFailed(
                name: downloadTask.originalRequest?.url?.lastPathComponent ?? "model",
                reason: "HTTP \(response.statusCode)"
            )))
            return
        }

        do {
            let scratch = try AppPaths.ensureDirectory(AppPaths.downloads)
            let destination = scratch.appendingPathComponent(UUID().uuidString + ".partial")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(with: .success(destination))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }  // success is delivered by the method above
        if (error as? URLError)?.code == .cancelled {
            finish(with: .failure(CancellationError()))
        } else {
            finish(with: .failure(error))
        }
    }
}
