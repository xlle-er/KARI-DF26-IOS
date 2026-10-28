import Foundation
import Combine
import AVFoundation
import UIKit
import MediaPipeTasksVision

// Owns one serial inference worker. Admission happens before retaining a camera frame.
final class KariVisionService: ObservableObject, @unchecked Sendable {
    @Published private(set) var enabled = false
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var latencyMs = 0.0
    @Published private(set) var message = ""
    var onDetections: (([Detection]) -> Void)?
    private let worker = DispatchQueue(label: "app.kari.detection", qos: .userInitiated)
    private let lock = NSLock()
    private var wanted = false, busy = false
    private var generation = 0, sequence = 0
    private var lastSubmission = -Double.infinity
    private var detector: ObjectDetector?
    @MainActor func setEnabled(_ value: Bool) {
        lock.lock(); wanted = value; generation += 1; lastSubmission = -.infinity; lock.unlock()
        enabled = value; detections = []; message = ""
        onDetections?([])
        if !value { worker.async { self.detector = nil } }
    }
    @MainActor func invalidate() {
        lock.lock(); generation += 1; lastSubmission = -.infinity; lock.unlock()
        detections = []; onDetections?([])
    }
    // Called on the capture queue before any frame in the new orientation is admitted.
    func orientationChanged(clockwise turns: Int, completion: @escaping @MainActor () -> Void) {
        lock.lock(); generation += 1; lastSubmission = -.infinity; lock.unlock()
        DispatchQueue.main.async { self.detections = []; completion() }
    }
    static func fixtureDetections(_ image: UIImage) throws -> [String] {
        guard let url = Bundle.module.url(forResource: "efficientdet_lite0", withExtension: "tflite", subdirectory: "Models") else { throw PolicyError.invalidProfile }
        let options = ObjectDetectorOptions(); options.baseOptions.modelAssetPath = url.path
        options.runningMode = .image; options.scoreThreshold = 0.6; options.maxResults = 12
        let detector = try ObjectDetector(options: options)
        return try detector.detect(image: MPImage(uiImage: image)).detections.compactMap { $0.categories.max(by: { $0.score < $1.score })?.categoryName }
    }
    func submit(_ buffer: CVPixelBuffer, time: Double) {
        lock.lock()
        let thermal = ProcessInfo.processInfo.thermalState
        let interval = thermal == .serious || thermal == .critical ? 0.5 : 0.1
        guard wanted, !busy, time - lastSubmission >= interval else { lock.unlock(); return }
        busy = true; lastSubmission = time; let token = generation
        lock.unlock()
        worker.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            do {
                if self.detector == nil {
                    guard let url = Bundle.module.url(forResource: "efficientdet_lite0", withExtension: "tflite", subdirectory: "Models") else { throw PolicyError.invalidProfile }
                    let options = ObjectDetectorOptions(); options.baseOptions.modelAssetPath = url.path
                    options.runningMode = .video; options.scoreThreshold = 0.6; options.maxResults = 12
                    self.detector = try ObjectDetector(options: options)
                }
                let started = ProcessInfo.processInfo.systemUptime
                let image = try MPImage(pixelBuffer: buffer, orientation: .up)
                let result = try self.detector!.detect(videoFrame: image, timestampInMilliseconds: Int(time * 1000))
                let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer))
                let values: [Detection] = result.detections.compactMap { item in
                    guard let category = item.categories.max(by: { $0.score < $1.score }) else { return nil }
                    self.sequence += 1
                    let b = item.boundingBox
                    return Detection(id: self.sequence, label: category.categoryName ?? "object", score: Double(category.score), box: .init(x: Double(b.minX) / width, y: Double(b.minY) / height, width: Double(b.width) / width, height: Double(b.height) / height), time: time)
                }
                let latency = (ProcessInfo.processInfo.systemUptime - started) * 1000
                DispatchQueue.main.async {
                    self.lock.lock(); let valid = self.wanted && self.generation == token; self.lock.unlock()
                    guard valid else { return }
                    self.latencyMs = latency; self.detections = values
                    self.message = thermal == .serious || thermal == .critical ? "设备温度较高，检测已降频，跟随暂停" : ""
                    self.onDetections?(values)
                }
            } catch {
                self.detector = nil
                DispatchQueue.main.async {
                    self.lock.lock(); let valid = self.generation == token; self.lock.unlock()
                    guard valid else { return }
                    self.setEnabled(false); self.message = "本地识别模型无法加载，语音和相机仍可使用"
                }
            }
        }
    }
}
