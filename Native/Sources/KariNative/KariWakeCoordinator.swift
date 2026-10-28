import Foundation
import Combine
import Speech
import AVFoundation

@MainActor final class WakeCoordinator: ObservableObject {
    @Published private(set) var phase = WakePhase.stopped
    @Published private(set) var message = ""
    @Published private(set) var availability = "尚未检查本地识别"
    @Published private(set) var wakeCount = 0
    @Published private(set) var overflowCount = 0
    private(set) var policy = WakePolicy()
    weak var app: KariAppModel?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognitionID = UUID()
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var runID = UUID()
    private var settings = WakeSettings()
    private var observedHeard = ""
    var now: Double { ProcessInfo.processInfo.systemUptime }
    var running: Bool { phase != .stopped && phase != .suspended }
    var mayUpload: Bool { phase == .conversation }
    func checkAvailability(_ preset: WakePreset, requestPermission: Bool) async -> Bool {
        let status: SFSpeechRecognizerAuthorizationStatus
        if requestPermission {
            status = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        } else { status = SFSpeechRecognizer.authorizationStatus() }
        guard status == .authorized else { availability = "请允许语音识别；仍可手动唤醒"; return false }
        guard let service = SFSpeechRecognizer(locale: Locale(identifier: preset.locale)), service.supportsOnDeviceRecognition else {
            availability = "此语言的本地识别不可用；仍可手动唤醒"; return false
        }
        guard service.isAvailable else { availability = "本地语音识别暂不可用；仍可手动唤醒"; return false }
        availability = "本地识别可用，不上传等待期间的声音"; return true
    }
    func begin(_ value: WakeSettings) async {
        stop(); settings = value; let id = UUID(); runID = id
        // Enter the local-only gate before requesting any permission.
        policy.wait(now: now); sync(); message = "等待唤醒"
        let allowed = await checkAvailability(value.preset, requestPermission: true)
        guard runID == id, phase == .waiting, let app else { return }
        do {
            try await app.live.startSharedCapture(onFrame: { [weak self] data, level in self?.frame(data, level: level) }, onState: { [weak self] type, _ in
                guard type != "started", let self else { return }; self.suspend(reason: "音频采集已中断，请手动恢复")
            })
            guard runID == id, phase == .waiting else { return }
            if allowed { startRecognition() } else { message = availability }
        } catch {
            guard runID == id else { return }; app.live.endSharedCapture(); message = "麦克风不可用，请检查权限后重试"
        }
        guard runID == id else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled, self.runID == id else { return }; self.tick()
            }
        }
    }
    private func startRecognition() {
        cancelRecognition()
        guard phase == .waiting, let service = SFSpeechRecognizer(locale: Locale(identifier: settings.preset.locale)),
              service.supportsOnDeviceRecognition, service.isAvailable, SFSpeechRecognizer.authorizationStatus() == .authorized else {
            message = "本地语音识别暂不可用；仍可手动唤醒"; return
        }
        recognizer = service
        let input = SFSpeechAudioBufferRecognitionRequest()
        input.requiresOnDeviceRecognition = true; input.shouldReportPartialResults = true
        input.contextualStrings = settings.preset == .chinese ? ["你好卡里", "你好卡里"] : ["Hey KARI"]
        request = input
        let id = UUID(); recognitionID = id
        recognition = service.recognitionTask(with: input) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recognitionID == id, self.phase == .waiting else { return }
                if let result, self.settings.preset.matches(result.bestTranscription.formattedString) { self.wake(); return }
                if error != nil {
                    self.cancelRecognition(); self.message = "本地识别失败：\(KariAIRequest.redact(error?.localizedDescription ?? ""))；请手动唤醒或重试"; self.app?.companion.record("wake_recognition_failed"); return
                }
                // A final recognition result is a normal utterance boundary, not
                // an error retry. A fresh local request permits long waiting.
                if result?.isFinal == true { self.startRecognition() }
            }
        }
    }
    private func cancelRecognition() {
        recognitionID = UUID(); request?.endAudio(); recognition?.cancel()
        recognition = nil; request = nil; recognizer = nil
    }
    private func frame(_ pcm: Data, level: Double) {
        let forward = policy.append(pcm, now: now, voice: level > 0.02 && phase == .conversation && app?.live.speaking != true)
        if let forward { app?.live.sendPCM(forward, level: level) }
        guard phase == .waiting, let request, pcm.count.isMultiple(of: 2),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)), let target = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        pcm.withUnsafeBytes { bytes in if let base = bytes.baseAddress { memcpy(target, base, pcm.count) } }
        request.append(buffer)
    }
    func wake() {
        guard let app, app.phase == .active, let ticket = policy.wake(now: now) else { return }
        sync(); cancelRecognition(); wakeCount += 1; message = "正在连接实时对话"
        app.companion.lifeEvent("wake"); app.companion.record("wake_detected")
        let id = runID
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await app.live.start(app.settings.configuration, captureMicrophone: false)
                guard id == self.runID, !Task.isCancelled, self.policy.phase == .connecting else { return }
                // A manual wake can recover after denied/interrupted microphone.
                if !app.live.microphone {
                    try await app.live.startSharedCapture(onFrame: { [weak self] pcm, level in self?.frame(pcm, level: level) }, onState: { [weak self] type, _ in if type != "started" { self?.suspend(reason: "音频采集已中断，请手动恢复") } })
                }
                guard id == self.runID, !Task.isCancelled, let buffered = self.policy.connected(generation: ticket, now: self.now) else { return }
                self.sync(); self.observedHeard = app.live.heard
                if self.policy.overflow { self.overflowCount += 1; self.message = "连接已就绪，刚才的问题过长，请重新说一遍" }
                else { app.live.sendPCM(buffered); self.message = "可以连续对话" }
            } catch {
                guard id == self.runID, !Task.isCancelled else { return }
                app.live.stop(preserveCapture: true); self.policy.wait(now: self.now); self.sync()
                self.message = "实时连接失败，请手动唤醒重试"; app.companion.record("wake_connection_failed")
                // No automatic recognition or connection retry on failure.
            }
        }
    }
    func wait() {
        guard let app, app.phase == .active else { return }
        operation?.cancel(); cancelRecognition(); app.live.stop(preserveCapture: true); app.live.clearResumption()
        app.settings.motionEnabled = false; app.companion.cancelAutomatic(); app.motion.invalidate()
        Task { _ = await app.motion.stop() }
        policy.wait(now: now); sync(); message = "等待唤醒"; app.companion.record("wake_waiting")
        if app.live.microphone { startRecognition() }
    }
    private func tick() {
        guard let app else { return }
        if phase == .conversation {
            if !app.live.connected { wait(); cancelRecognition(); message = "实时连接失败，请手动唤醒重试"; return }
            let busy = app.live.speaking || app.live.processing || app.scenarioBusy || app.textBusy || app.remote.presented
            if busy || observedHeard != app.live.heard { observedHeard = app.live.heard; policy.activity(now: now) }
            if policy.timedOut(now: now, timeout: settings.silenceTimeout, busy: busy) { wait() }
        }
    }
    func suspend(reason: String) {
        runID = UUID(); operation?.cancel(); timer?.cancel(); cancelRecognition()
        policy.stop(suspended: true); sync(); message = reason
        app?.live.stop(); app?.settings.motionEnabled = false; app?.companion.cancelAutomatic()
        app?.motion.invalidate(); Task { _ = await app?.motion.stop() }
        app?.companion.lifeSuspend()
    }
    func resume() async { guard let app, app.phase == .active else { return }; await begin(app.companion.wakeSettings) }
    func stop() {
        runID = UUID(); operation?.cancel(); operation = nil; timer?.cancel(); timer = nil
        cancelRecognition(); policy.stop(); sync(); app?.live.stop()
    }
    private func sync() { phase = policy.phase }
}
