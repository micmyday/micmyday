import Foundation
import OSLog

/// Downloads and stores whisper.cpp GGML models under Application Support.
@MainActor
final class WhisperModelManager: NSObject, ObservableObject {
    static let shared = WhisperModelManager()

    private static let logger = Logger(subsystem: "com.micmyday.app", category: "WhisperModels")

    /// Model id → download progress in 0...1. Presence means a download is running.
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var installedModelIDs: Set<String> = []
    @Published private(set) var lastError: String?
    /// Model currently being loaded into memory for inference.
    @Published private(set) var loadingModelID: String?
    /// Model loaded, warmed up, and ready for instant dictation.
    @Published private(set) var readyModelID: String?

    private var tasksByModelID: [String: URLSessionDownloadTask] = [:]

    /// True when the callback belongs to the task currently registered for the
    /// model. Cancel-then-restart could otherwise let the old task's delayed
    /// completion remove its replacement, leaving a download running with no
    /// progress and no cancel button.
    private func isCurrentTask(_ identifier: Int, for modelID: String) -> Bool {
        tasksByModelID[modelID]?.taskIdentifier == identifier
    }
    private lazy var session = URLSession(
        configuration: .default,
        delegate: DownloadDelegate(manager: self),
        delegateQueue: nil
    )

    nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MicMyDay/WhisperModels", isDirectory: true)
    }

    nonisolated static func localURL(forModelID id: String) -> URL? {
        guard let model = WhisperModelCatalog.model(withID: id) else { return nil }
        return modelsDirectory.appendingPathComponent(model.fileName)
    }

    nonisolated static func isInstalled(modelID: String) -> Bool {
        if WhisperModelCatalog.model(withID: modelID)?.engine == .nemotron {
            // A directory of Core ML bundles, ready only once its one-time
            // compile has run; the engine keeps that record.
            return NemotronEngine.isReady(modelID)
        }
        guard let url = localURL(forModelID: modelID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    override private init() {
        super.init()
        refreshInstalledModels()
    }

    func refreshInstalledModels() {
        installedModelIDs = Set(
            WhisperModelCatalog.models
                .filter { Self.isInstalled(modelID: $0.id) }
                .map(\.id)
        )
    }

    func download(_ model: WhisperModel) {
        guard tasksByModelID[model.id] == nil, !installedModelIDs.contains(model.id) else { return }
        if model.engine == .nemotron {
            guard nemotronDownloadTask == nil else { return }
            lastError = nil
            downloadProgress[model.id] = 0
            // Every callback and cleanup below checks this attempt is still
            // the current one, so a cancelled attempt's tail cannot wipe the
            // progress or the handle of the attempt started after it.
            nemotronDownloadAttempt += 1
            let attempt = nemotronDownloadAttempt
            let task = Task { [weak self] in
                do {
                    try await NemotronEngine.downloadAndPrepare(modelID: model.id) { fraction in
                        guard let self, self.nemotronDownloadAttempt == attempt else { return }
                        self.downloadProgress[model.id] = fraction
                    }
                    guard let self else { return }
                    // A run that finished after being superseded still owns
                    // its handle and its progress row; only the state that
                    // belongs to the current attempt is fenced.
                    if self.nemotronDownloadAttempt == attempt {
                        self.refreshInstalledModels()
                    }
                    if self.nemotronDownloadTask?.attempt == attempt {
                        self.downloadProgress[model.id] = nil
                        self.nemotronDownloadTask = nil
                    }
                } catch {
                    // A cancellation arrives in two spellings, the Swift one
                    // and the URL loader's. Neither is a failure.
                    let cancelled = error is CancellationError
                        || (error as? URLError)?.code == .cancelled
                        || Task.isCancelled
                    guard let self else { return }
                    if self.nemotronDownloadAttempt == attempt, !cancelled {
                        self.lastError = "The model could not be downloaded: \(error.localizedDescription)"
                    }
                    // Only this attempt's own tail releases the handle and
                    // its progress row: that is the event that says its
                    // filesystem work has truly stopped, and `download`
                    // refuses to start a retry while any handle stands. The
                    // lingering progress row is deliberate — it is what shows
                    // a cancelled download still winding down instead of a
                    // Get button that silently swallows the click.
                    if self.nemotronDownloadTask?.attempt == attempt {
                        self.downloadProgress[model.id] = nil
                        self.nemotronDownloadTask = nil
                    }
                    // Cleanup after cancellation, once nothing newer owns the
                    // directory and no prepared model stands.
                    if cancelled, self.nemotronDownloadTask == nil, !NemotronEngine.isReady(model.id) {
                        NemotronEngine.delete(model.id)
                    }
                }
            }
            nemotronDownloadTask = (attempt, task)
            return
        }
        lastError = nil
        downloadProgress[model.id] = 0
        let task = session.downloadTask(with: model.downloadURL)
        task.taskDescription = model.id
        tasksByModelID[model.id] = task
        task.resume()
        Self.logger.info("Started model download: \(model.id, privacy: .public)")
    }

    func cancelDownload(_ modelID: String) {
        lastError = nil
        if WhisperModelCatalog.model(withID: modelID)?.engine == .nemotron {
            nemotronDownloadAttempt += 1
            // Cancelled but not released: the handle and the progress row
            // fall only when the task's own tail runs, which is what holds a
            // retry off the directory until the cancelled download has
            // stopped writing — and what keeps the row visibly busy instead
            // of showing a Get button that would swallow the click.
            nemotronDownloadTask?.task.cancel()
            return
        }
        tasksByModelID[modelID]?.cancel()
        tasksByModelID[modelID] = nil
        downloadProgress[modelID] = nil
    }

    /// The one in-flight Nemotron download-and-prepare, so a second click
    /// cannot start a competing copy of a multi-hundred-megabyte fetch. The
    /// handle stays until its task's own tail clears it, even after a
    /// cancel: a retry that started while the cancelled attempt's download
    /// callbacks were still writing shared the very directory the tail was
    /// about to delete.
    private var nemotronDownloadTask: (attempt: Int, task: Task<Void, Never>)?
    /// Which attempt owns the handle above; see `download`.
    private var nemotronDownloadAttempt = 0

    func delete(_ modelID: String) {
        // Deleting the file out from under an in-flight load leaves the
        // engine warmed for a model that no longer exists; the invariant
        // belongs here, not only in the row's enablement logic.
        guard loadingModelID != modelID else { return }
        if WhisperModelCatalog.model(withID: modelID)?.engine == .nemotron {
            lastError = nil
            NemotronEngine.delete(modelID)
            refreshInstalledModels()
            if readyModelID == modelID { readyModelID = nil }
            return
        }
        guard let url = Self.localURL(forModelID: modelID) else { return }
        // Deleting is the documented repair for a model that failed to load,
        // so the warning about it must not outlive the file.
        lastError = nil
        try? FileManager.default.removeItem(at: url)
        refreshInstalledModels()
        WhisperCppEngine.shared.unloadIfCached(modelPath: url.path)
        if readyModelID == modelID { readyModelID = nil }
        if loadingModelID == modelID { loadingModelID = nil }
    }

    /// Loads the selected model into the inference engine ahead of the first
    /// dictation, publishing loading/ready state for the UI. Safe to call
    /// repeatedly; a model that is already ready or loading is not reloaded.
    func preloadSelectedModel(id: String) {
        guard readyModelID != id, loadingModelID != id else { return }
        // The Core ML engine was compiled at download time and its managers
        // are created per dictation; there is nothing here to warm.
        guard WhisperModelCatalog.model(withID: id)?.engine != .nemotron else { return }
        guard
            let model = WhisperModelCatalog.model(withID: id),
            let url = Self.localURL(forModelID: id),
            FileManager.default.fileExists(atPath: url.path)
        else { return }

        loadingModelID = id
        // A failure from a previous model must not keep flying the flag once
        // a load is under way for the current one.
        lastError = nil
        if readyModelID != id { readyModelID = nil }
        Task {
            do {
                try await WhisperCppEngine.shared.preload(modelPath: url.path, engine: model.engine)
                if loadingModelID == id {
                    loadingModelID = nil
                    readyModelID = id
                }
            } catch {
                // Only report a failure that belongs to the load still in
                // flight. A superseded model finishing late used to overwrite
                // the cleared error, leaving a "could not be loaded" warning
                // on screen next to a model that had gone Ready.
                guard loadingModelID == id else { return }
                loadingModelID = nil
                lastError = "The model could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    fileprivate func updateProgress(modelID: String, taskIdentifier: Int, fraction: Double) {
        guard isCurrentTask(taskIdentifier, for: modelID) else { return }
        if downloadProgress[modelID] != nil {
            downloadProgress[modelID] = fraction
        }
    }

    fileprivate func finishDownload(
        modelID: String,
        taskIdentifier: Int,
        temporaryFileMovedTo destination: URL?,
        error: Error?
    ) {
        guard isCurrentTask(taskIdentifier, for: modelID) else { return }
        tasksByModelID[modelID] = nil
        downloadProgress[modelID] = nil
        if let error {
            if (error as? URLError)?.code != .cancelled {
                lastError = "Model download failed: \(error.localizedDescription)"
                Self.logger.error("Model download failed: \(modelID, privacy: .public), \(error.localizedDescription, privacy: .public)")
            }
        } else if destination != nil {
            Self.logger.info("Model download finished: \(modelID, privacy: .public)")
        }
        refreshInstalledModels()
    }
}

/// URLSession delegate callbacks arrive on a background queue; the file move must
/// happen synchronously inside didFinishDownloadingTo before the temp file is reclaimed.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var manager: WhisperModelManager?

    init(manager: WhisperModelManager) {
        self.manager = manager
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let modelID = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let identifier = downloadTask.taskIdentifier
        Task { @MainActor [weak manager] in
            manager?.updateProgress(modelID: modelID, taskIdentifier: identifier, fraction: fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let modelID = downloadTask.taskDescription else { return }

        var moveError: Error?
        var destination: URL?
        if let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(statusCode) {
            moveError = URLError(.badServerResponse)
        } else {
            do {
                let directory = WhisperModelManager.modelsDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(location.lastPathComponent)
                    .deletingLastPathComponent()
                    .appendingPathComponent(WhisperModelCatalog.model(withID: modelID)?.fileName ?? "ggml-\(modelID).bin")
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: location, to: target)
                destination = target
            } catch {
                moveError = error
            }
        }

        let finalError = moveError
        let finalDestination = destination
        let identifier = downloadTask.taskIdentifier
        Task { @MainActor [weak manager] in
            manager?.finishDownload(
                modelID: modelID,
                taskIdentifier: identifier,
                temporaryFileMovedTo: finalDestination,
                error: finalError
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let modelID = task.taskDescription else { return }
        let identifier = task.taskIdentifier
        Task { @MainActor [weak manager] in
            manager?.finishDownload(
                modelID: modelID,
                taskIdentifier: identifier,
                temporaryFileMovedTo: nil,
                error: error
            )
        }
    }
}
