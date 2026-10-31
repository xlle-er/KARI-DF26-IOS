import Foundation
import Combine
import CryptoKit
import Network

@MainActor final class KariModelDownloads: NSObject, ObservableObject {
    let catalog: [KariLocalEmbeddingModel]
    nonisolated let root: URL
    let engine: KariLocalEmbedding
    @Published private(set) var activeID = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published private(set) var sourceName = ""
    @Published private(set) var revision = 0
    @Published private(set) var cellular = false
    @Published private(set) var installedIDs = Set<String>()
    private let monitor = NWPathMonitor()
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var probe: Task<Void, Never>?
    private var candidates: [URL] = []
    private var model: KariLocalEmbeddingModel?
    private var generation = UUID()
    init(root: URL, engine: KariLocalEmbedding) {
        self.root = root; self.engine = engine
        if let folder = Bundle.module.url(forResource: "Models", withExtension: nil), let data = try? Data(contentsOf: folder.appendingPathComponent("embedding-catalog.json")) {
            catalog = (try? JSONDecoder().decode([KariLocalEmbeddingModel].self, from: data)) ?? []
        } else { catalog = [] }
        super.init()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default; config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: KariModelDownloadDelegate(owner: self), delegateQueue: nil)
        installedIDs = Set(catalog.filter { FileManager.default.fileExists(atPath: file($0).path) && FileManager.default.fileExists(atPath: receipt($0).path) }.map(\.id))
        monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.cellular = path.isExpensive } }
        monitor.start(queue: DispatchQueue(label: "kari.models.network"))
    }
    deinit { monitor.cancel(); session?.invalidateAndCancel() }
    func file(_ model: KariLocalEmbeddingModel) -> URL { root.appendingPathComponent(model.id + "-" + model.sha256.prefix(12) + ".gguf") }
    private func receipt(_ model: KariLocalEmbeddingModel) -> URL { file(model).appendingPathExtension("verified") }
    func installed(_ model: KariLocalEmbeddingModel) -> Bool { installedIDs.contains(model.id) }
    func remove(_ model: KariLocalEmbeddingModel) async throws {
        guard activeID != model.id else { throw KariError.message("请先暂停模型下载") }
        await engine.unload()
        try? FileManager.default.removeItem(at: file(model)); try? FileManager.default.removeItem(at: receipt(model))
        installedIDs.remove(model.id); revision += 1
    }
    func download(_ value: KariLocalEmbeddingModel, source: String) {
        guard activeID.isEmpty else { return }
        generation = UUID(); let token = generation
        activeID = value.id; model = value; progress = 0; status = "正在检查下载源…"
        probe = Task {
            do {
                let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard capacity > value.bytes + 100_000_000 else { throw KariError.message("剩余空间不足，请释放空间后重试") }
                let urls = source == "hf" ? [value.url] : source == "ms" ? value.mirrors.compactMap(URL.init(string:)) : [value.url] + value.mirrors.compactMap(URL.init(string:))
                guard !urls.isEmpty else { throw KariError.message("此模型尚无通过哈希核验的魔搭镜像，请选择自动或 Hugging Face") }
                let available = await withTaskGroup(of: (URL, Double)?.self) { group -> [(URL, Double)] in
                    for url in urls { group.addTask {
                        var request = URLRequest(url: url, timeoutInterval: 5); request.httpMethod = "HEAD"
                        let start = Date()
                        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                        if http.expectedContentLength > 0 && http.expectedContentLength != value.bytes { return nil }
                        return (url, Date().timeIntervalSince(start))
                    } }
                    var results: [(URL, Double)] = []; for await result in group { if let result { results.append(result) } }; return results.sorted { $0.1 < $1.1 }
                }
                try Task.checkCancellation(); guard token == generation else { return }
                candidates = available.map(\.0)
                guard !candidates.isEmpty else { throw KariError.message("下载源不可达或需要授权，请切换网络或手动选择来源") }
                startNext()
            } catch { if token == generation { if !candidates.isEmpty { startNext() } else { status = error.localizedDescription; activeID = "" } } }
        }
    }
    private func startNext() {
        guard let model, !candidates.isEmpty else { activeID = ""; status = "下载失败，两个来源均不可用；可稍后重试"; return }
        let url = candidates.removeFirst()
        sourceName = url.host?.contains("modelscope") == true ? "魔搭 ModelScope" : "Hugging Face"
        let resume = root.appendingPathComponent(model.id + ".resume")
        let sourceFile = resume.appendingPathExtension("source")
        if let data = try? Data(contentsOf: resume), (try? String(contentsOf: sourceFile, encoding: .utf8)) == url.absoluteString {
            task = session.downloadTask(withResumeData: data)
        } else { task = session.downloadTask(with: url) }
        try? url.absoluteString.write(to: sourceFile, atomically: true, encoding: .utf8)
        task?.taskDescription = generation.uuidString
        status = "正在下载 · \(sourceName)"; task?.resume()
    }
    func pause() {
        probe?.cancel(); probe = nil
        guard let model else { activeID = ""; return }
        let token = generation; generation = UUID()
        let resumeURL = root.appendingPathComponent(model.id + ".resume")
        task?.cancel { data in if let data { try? data.write(to: resumeURL, options: .atomic) } }
        task = nil; activeID = ""; status = "下载已暂停，可继续"; _ = token
    }
    private func finish(_ staging: URL, taskID: String?) async {
        defer { try? FileManager.default.removeItem(at: staging) }
        guard taskID == generation.uuidString, let model else { return }
        let token = generation
        status = "正在校验文件并测试模型…"
        do {
            let actual = try await Task.detached(priority: .utility) { () throws -> String in
                let handle = try FileHandle(forReadingFrom: staging); defer { try? handle.close() }
                var hash = SHA256(); var total: Int64 = 0
                while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { total += Int64(block.count); hash.update(data: block) }
                guard total == model.bytes else { throw KariError.message("模型大小不符，请重新下载") }
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
            guard actual == model.sha256 else { throw KariError.message("模型校验失败，文件未安装") }
            _ = try await engine.embed("测试模型", query: true, config: model, url: staging)
            await engine.unload()
            guard token == generation else { return }
            let target = file(model)
            try? FileManager.default.removeItem(at: target); try FileManager.default.moveItem(at: staging, to: target)
            try model.sha256.write(to: receipt(model), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(model.id + ".resume"))
            installedIDs.insert(model.id); revision += 1; status = "模型已下载并通过加载测试"; activeID = ""; task = nil
        } catch { guard token == generation else { return }; if !candidates.isEmpty { startNext() } else { status = error.localizedDescription; activeID = ""; task = nil } }
    }
}
extension KariModelDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription
        Task { @MainActor in guard id == generation.uuidString else { return }; progress = Double(totalBytesWritten) / Double(max(1, totalBytesExpectedToWrite)) }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let staging = root.appendingPathComponent("staging-" + UUID().uuidString)
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw KariError.message("模型下载请求失败") }
            try FileManager.default.moveItem(at: location, to: staging)
            let id = downloadTask.taskDescription
            Task { @MainActor in await finish(staging, taskID: id) }
        } catch { let id = downloadTask.taskDescription; Task { @MainActor in guard id == generation.uuidString else { return }; if !candidates.isEmpty { startNext() } else { status = error.localizedDescription; activeID = "" } } }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }; let id = task.taskDescription; let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard id == generation.uuidString else { return }
            if let resume, let model { try? resume.write(to: root.appendingPathComponent(model.id + ".resume"), options: .atomic) }
            if !candidates.isEmpty { startNext() }
            else { activeID = ""; status = "下载中断，可继续：" + error.localizedDescription }
        }
    }
}

// URLSession retains its delegate. Keep that edge weak so test instances and replaced services release their sessions.
private final class KariModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: KariModelDownloads?
    init(owner: KariModelDownloads) { self.owner = owner }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        owner?.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        owner?.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
