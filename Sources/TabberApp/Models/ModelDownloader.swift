import Foundation

/// URLSession download tasks for model files. Runs its delegate on a private serial queue, validates
/// finished files there (size and GGUF magic), and moves them into place atomically.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Job: Sendable {
        let id: String
        let url: URL
        let expectedSize: Int64
        let destination: URL
    }

    enum Outcome: Sendable, Equatable {
        case completed
        case cancelled
        case failed(String)
    }

    enum Event: Sendable {
        case progress(String, Double)
        case resumeData(String, Data)
        case finished(String, Outcome)
    }

    /// Called on the delegate queue.
    var onEvent: (@Sendable (Event) -> Void)?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "app.tabber.downloads"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    // Guarded by `lock`.
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var lastReported: [String: Double] = [:]
    private var outcomes: [String: Outcome] = [:]
    private var discardResumeData: Set<String> = []

    func start(_ job: Job, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: job.url)
        }
        task.taskDescription = job.id
        lock.withLock {
            jobs[job.id] = job
            tasks[job.id] = task
            lastReported[job.id] = 0
            outcomes[job.id] = nil
            discardResumeData.remove(job.id)
        }
        task.resume()
    }

    func cancel(_ id: String, keepResumeData: Bool) {
        let task: URLSessionDownloadTask? = lock.withLock {
            if !keepResumeData { discardResumeData.insert(id) }
            outcomes[id] = .cancelled
            return tasks[id]
        }
        guard let task else { return }
        if keepResumeData {
            task.cancel { [weak self] data in
                if let data { self?.onEvent?(.resumeData(id, data)) }
            }
        } else {
            task.cancel()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, isCurrent(downloadTask, id) else { return }
        let total: Int64 = lock.withLock {
            let expected = jobs[id]?.expectedSize ?? 0
            return expected > 0 ? expected : totalBytesExpectedToWrite
        }
        guard total > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(total))
        let shouldReport: Bool = lock.withLock {
            let last = lastReported[id] ?? 0
            guard fraction - last >= 0.002 || fraction >= 1 else { return false }
            lastReported[id] = fraction
            return true
        }
        if shouldReport { onEvent?(.progress(id, fraction)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, isCurrent(downloadTask, id), let job = lock.withLock({ jobs[id] }) else { return }
        // The file at `location` is deleted when this method returns, so validate and move it now.
        let outcome = Self.install(location, job: job, response: downloadTask.response)
        lock.withLock { outcomes[id] = outcome }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A task replaced by a newer download of the same model reports nothing.
        guard let id = task.taskDescription, isCurrent(task, id) else { return }
        let (recorded, discard): (Outcome?, Bool) = lock.withLock {
            defer {
                jobs[id] = nil
                tasks[id] = nil
                lastReported[id] = nil
                outcomes[id] = nil
            }
            return (outcomes[id], discardResumeData.remove(id) != nil)
        }

        if let error = error as NSError? {
            if !discard, let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                onEvent?(.resumeData(id, data))
            }
            if error.code == NSURLErrorCancelled || recorded == .cancelled {
                onEvent?(.finished(id, .cancelled))
            } else {
                onEvent?(.finished(id, .failed(error.localizedDescription)))
            }
            return
        }
        onEvent?(.finished(id, recorded ?? .failed("The download ended unexpectedly.")))
    }

    private func isCurrent(_ task: URLSessionTask, _ id: String) -> Bool {
        lock.withLock { tasks[id] === task }
    }

    // MARK: Validation

    private static func install(_ location: URL, job: Job, response: URLResponse?) -> Outcome {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failed("The server returned an error (\(http.statusCode)).")
        }
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == job.expectedSize else {
            return .failed("The downloaded file is incomplete. Try again.")
        }
        guard hasGGUFMagic(location) else {
            return .failed("The downloaded file isn't a GGUF model.")
        }
        // Stage next to the destination (same volume), then rename over it in one step.
        let staging = job.destination.deletingLastPathComponent()
            .appendingPathComponent(".\(job.destination.lastPathComponent).download")
        do {
            try? fm.removeItem(at: staging)
            try fm.moveItem(at: location, to: staging)
            // URLSession creates its files owner-only; models are ordinary documents.
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staging.path)
            guard rename(staging.path, job.destination.path) == 0 else {
                try? fm.removeItem(at: staging)
                return .failed("Couldn't save the model: \(String(cString: strerror(errno))).")
            }
            return .completed
        } catch {
            return .failed("Couldn't save the model: \(error.localizedDescription)")
        }
    }

    private static func hasGGUFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data("GGUF".utf8)
    }
}
