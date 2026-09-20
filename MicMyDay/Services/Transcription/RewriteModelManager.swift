import Foundation
import OSLog

/// Downloads and stores the GGUF rewrite models under Application Support.
///
/// Deliberately a sibling of `WhisperModelManager` rather than a generalisation
/// of it. The two hold different kinds of file in different directories, and the
/// one thing they would share, a download queue, is already `URLSession`.
@MainActor
final class RewriteModelManager: NSObject, ObservableObject {
    static let shared = RewriteModelManager()

    private static let logger = Logger(subsystem: "com.micmyday.app", category: "RewriteModels")

    /// Model id → progress in 0...1. Presence means a download is running.
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var installedModelIDs: Set<String> = []
    @Published private(set) var lastError: String?

    private var tasksByModelID: [String: URLSessionDownloadTask] = [:]

    /// True when the callback belongs to the task currently registered for the
    /// model. Cancelling and restarting could otherwise let the old task's late
    /// completion clear its replacement, leaving a download running with no
    /// progress shown and no way to cancel it.
    private func isCurrentTask(_ identifier: Int, for modelID: String) -> Bool {
        tasksByModelID[modelID]?.taskIdentifier == identifier
    }

    private lazy var session = URLSession(
        configuration: .default,
        delegate: RewriteDownloadDelegate(manager: self),
        delegateQueue: nil
    )

    nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MicMyDay/RewriteModels", isDirectory: true)
    }

    nonisolated static func localURL(forModelID id: String) -> URL? {
        guard let model = RewriteModelCatalog.model(withID: id), let download = model.download else { return nil }
        return modelsDirectory.appendingPathComponent(download.file)
    }

    nonisolated static func isInstalled(modelID: String) -> Bool {
        guard let url = localURL(forModelID: modelID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    override private init() {
        super.init()
        refreshInstalledModels()
    }

    func refreshInstalledModels() {
        installedModelIDs = Set(
            RewriteModelCatalog.downloadable
                .filter { Self.isInstalled(modelID: $0.id) }
                .map(\.id)
        )
    }

    func download(_ model: LocalRewriteModel) {
        guard let download = model.download else { return }
        guard tasksByModelID[model.id] == nil, !installedModelIDs.contains(model.id) else { return }
        lastError = nil
        downloadProgress[model.id] = 0
        let task = session.downloadTask(with: download.url)
        task.taskDescription = model.id
        tasksByModelID[model.id] = task
        task.resume()
        Self.logger.info("Started rewrite model download: \(model.id, privacy: .public)")
    }

    func cancelDownload(_ modelID: String) {
        lastError = nil
        tasksByModelID[modelID]?.cancel()
        tasksByModelID[modelID] = nil
        downloadProgress[modelID] = nil
    }

    func delete(_ modelID: String) {
        guard let url = Self.localURL(forModelID: modelID) else { return }
        // Deleting is the documented repair for a model that will not load, so
        // the warning about it must not outlive the file.
        lastError = nil
        try? FileManager.default.removeItem(at: url)
        refreshInstalledModels()
        // The engine holds the weights open. Dropping them here rather than on
        // the next rewrite means the memory goes back when the file does, and a
        // model cannot be used after its file has gone.
        LlamaCppEngine.shared.unloadIfCached(modelPath: url.path)
        if readyModelID == modelID { readyModelID = nil }
        if loadingModelID == modelID { loadingModelID = nil }
    }

    /// Model currently being read into memory.
    @Published private(set) var loadingModelID: String?
    /// Model loaded and ready, so the next rewrite starts immediately.
    @Published private(set) var readyModelID: String?

    /// Reads the selected model into the engine ahead of the first rewrite.
    /// Apple's built-in model is not ours to load, and a model that has not
    /// been downloaded has nothing to read. Safe to call repeatedly.
    func preloadModel(id: String) {
        guard readyModelID != id, loadingModelID != id else { return }
        guard let model = RewriteModelCatalog.model(withID: id), !model.isAppleBuiltIn else { return }
        guard let url = Self.localURL(forModelID: id), FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        loadingModelID = id
        // A failure from a previous model must not keep flying the flag once a
        // load is under way for the current one.
        lastError = nil
        if readyModelID != id { readyModelID = nil }
        Task {
            do {
                try await LlamaCppEngine.shared.preload(modelPath: url.path)
                guard loadingModelID == id else { return }
                loadingModelID = nil
                readyModelID = id
            } catch {
                // Only report a failure belonging to the load still in flight.
                // A superseded model finishing late would otherwise overwrite
                // the cleared error and leave a warning next to a model that
                // had gone ready.
                guard loadingModelID == id else { return }
                loadingModelID = nil
                lastError = "\(model.displayName) could not be loaded. Deleting and downloading it again usually fixes this."
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
        succeeded: Bool,
        error: Error?
    ) {
        guard isCurrentTask(taskIdentifier, for: modelID) else { return }
        tasksByModelID[modelID] = nil
        downloadProgress[modelID] = nil
        if let error {
            if (error as? URLError)?.code != .cancelled {
                lastError = "The download failed: \(error.localizedDescription)"
                Self.logger.error("Rewrite model download failed: \(modelID, privacy: .public), \(error.localizedDescription, privacy: .public)")
            }
        } else if succeeded {
            Self.logger.info("Rewrite model download finished: \(modelID, privacy: .public)")
        }
        refreshInstalledModels()
    }
}

/// URLSession calls back on a background queue, and the downloaded file is
/// reclaimed the moment `didFinishDownloadingTo` returns, so the move has to
/// happen synchronously inside it rather than hopping to the main actor first.
private final class RewriteDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var manager: RewriteModelManager?

    init(manager: RewriteModelManager) {
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
        var moved = false
        if let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(statusCode) {
            moveError = URLError(.badServerResponse)
        } else if let target = RewriteModelManager.localURL(forModelID: modelID) {
            do {
                try FileManager.default.createDirectory(
                    at: RewriteModelManager.modelsDirectory,
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: location, to: target)
                moved = true
            } catch {
                moveError = error
            }
        } else {
            moveError = URLError(.cannotCreateFile)
        }

        let finalError = moveError
        let succeeded = moved
        let identifier = downloadTask.taskIdentifier
        Task { @MainActor [weak manager] in
            manager?.finishDownload(
                modelID: modelID,
                taskIdentifier: identifier,
                succeeded: succeeded,
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
                succeeded: false,
                error: error
            )
        }
    }
}
