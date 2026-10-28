import Foundation
import Combine
import AVFoundation

@MainActor final class KariCompanionFeatures: ObservableObject {
    @Published private(set) var profile: PersonalityProfile
    @Published var behavior: BehaviorSettings {
        didSet {
            var normalized = behavior; normalized.normalize()
            if normalized != behavior { behavior = normalized; return }
            persist(); invalidateThought()
        }
    }
    @Published var idleSettings = IdleSceneSettings() { didSet { persist() } }
    @Published var wakeSettings = WakeSettings() { didSet { persist() } }
    @Published private(set) var lifeState = LifeState()
    let catalog = IdleScene.load()
    private var engine = LifeEngine()
    private var applyingConfiguration = false
    @Published private(set) var follow = FollowPolicy()
    @Published private(set) var followOnStart = false
    @Published private(set) var followMessage = "选择目标并设为参考"
    @Published private(set) var diagnostics: [String: String] = [:]
    @Published private(set) var events: [CompanionEvent] = []
    @Published private(set) var decisions: [CompanionEvent] = []
    @Published private(set) var message = ""
    let vision = KariVisionService()
    weak var app: KariAppModel?
    private var journal = CompanionJournal()
    private var scheduler = BehaviorCoordinator()
    private var pulse: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var thought: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var idleID = UUID()
    private var generation = UUID()
    private var thoughtGeneration = UUID()
    private var active = false
    private var lastDetectionEvent = -Double.infinity
    private var previousLabels = Set<String>()
    private var followLease: MotionLease?
    private var awaitingRotatedFrame = false
    private let defaults: UserDefaults
    var now: Double { ProcessInfo.processInfo.systemUptime }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profile = defaults.data(forKey: "kari.personality.v1").flatMap { try? PersonalityProfile.imported($0) } ?? PersonalityProfile()
        var settings = defaults.data(forKey: "kari.behavior.v1").flatMap { try? JSONDecoder().decode(BehaviorSettings.self, from: $0) } ?? BehaviorSettings()
        settings.normalize(); behavior = settings
        if let data = defaults.data(forKey: "kari.companion.v2"), let value = try? JSONDecoder().decode(CompanionConfiguration.self, from: data),
           let valid = try? value.validated(knownScenes: Set(catalog.map(\.id))) {
            profile = valid.profile; behavior = valid.behavior; idleSettings = valid.idle; wakeSettings = valid.wake
        }
        vision.onDetections = { [weak self] values in self?.detected(values) }
    }
    func attach(_ app: KariAppModel) { self.app = app }
    private func persist() {
        guard !applyingConfiguration else { return }
        if let data = try? exportedConfiguration() { defaults.set(data, forKey: "kari.companion.v2") }
    }
    func exportedConfiguration() throws -> Data {
        let value = CompanionConfiguration(profile: profile, behavior: behavior, idle: idleSettings, wake: wakeSettings)
        _ = try value.validated(knownScenes: Set(catalog.map(\.id)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(value)
    }
    func importConfiguration(_ data: Data) throws {
        guard !active, data.count <= 131_072 else { throw PolicyError.invalidProfile }
        let value = try JSONDecoder().decode(CompanionConfiguration.self, from: data).validated(knownScenes: Set(catalog.map(\.id)))
        applyingConfiguration = true
        profile = value.profile; behavior = value.behavior; idleSettings = value.idle; wakeSettings = value.wake
        applyingConfiguration = false; persist(); app?.live.clearResumption(); record("configuration_imported")
    }
    func lifeEvent(_ kind: String) { engine.event(kind, now: now); lifeState = engine.state }
    func lifeSuspend() { engine.suspend(); cancelAutomatic(); record("life_suspended") }
    func sceneOptions(_ id: String) -> IdleSceneOptions { idleSettings.options(id) }
    func setSceneOptions(_ value: IdleSceneOptions, id: String) {
        guard !active, (try? value.validate()) != nil else { return }; idleSettings.scenes[id] = value
    }
    func resetScenes() { guard !active else { return }; idleSettings = IdleSceneSettings() }
    func previewScene(_ scene: IdleScene) { app?.previewIdle(scene) }
    func cancelPreview() { app?.cancelIdlePreview() }
    var allowsAutomaticBody: Bool { app.map { !$0.companion.wakeSettings.enabled || !$0.settings.configuration.isLive || $0.wake.phase == .conversation } ?? false }

    func saveProfile(_ value: PersonalityProfile) throws {
        guard !active else { throw PolicyError.busy }
        let validated = try PersonalityProfile.imported(value.exported())
        defaults.set(try validated.exported(), forKey: "kari.personality.v1"); profile = validated
        persist(); app?.live.clearResumption(); message = "人格已保存"; record("personality_saved")
    }
    func importProfile(_ data: Data) throws { try saveProfile(PersonalityProfile.imported(data)) }
    func begin() {
        active = true; generation = UUID(); scheduler.begin(now: now); engine.begin(now: now, settings: idleSettings); lifeState = engine.state
        record("session_started")
        if followOnStart {
            guard let app, app.body.isConnected, app.settings.motionEnabled, follow.start(now: now) else { invalidateFollow("目标已失效，请退出陪伴重新选择"); startPulse(); return }
            startFollow()
        }
        startPulse()
    }
    func end() {
        active = false; engine.suspend(); generation = UUID(); invalidateThought(); idleTask?.cancel(); idleTask = nil
        pulse?.cancel(); pulse = nil; invalidateFollow("跟随已停止")
        vision.setEnabled(false); record("session_stopped"); refreshDiagnostics()
    }
    func interact() {
        scheduler.interact(now: now); lifeEvent("user_activity"); invalidateThought()
        if idleTask != nil {
            idleID = UUID(); idleTask?.cancel(); idleTask = nil
            app?.motion.stopCurrent(source: .idle)
        }
        record("user_activity")
    }
    private func invalidateThought() { thoughtGeneration = UUID(); thought?.cancel(); thought = nil }
    func cancelAutomatic() {
        invalidateThought(); idleID = UUID(); idleTask?.cancel(); idleTask = nil; invalidateFollow("跟随已停止，需重新选择目标")
    }
    func select(_ value: Detection) { guard !active else { return }; follow.select(value); followOnStart = false; followMessage = "目标已选择，请设为参考" }
    func calibrate() {
        guard !active else { return }
        followMessage = follow.calibrate(now: now) ? "参考已保存，可开启陪伴时跟随" : "目标已过期，请重新选择"
    }
    func armFollow(_ value: Bool) {
        guard !active else { return }
        guard !value || (follow.reference != nil && follow.fresh(now: now)) else { followMessage = "请先选择目标并设为参考"; return }
        followOnStart = value
    }
    func setDetection(_ value: Bool) {
        invalidateFollow("选择目标并设为参考"); vision.setEnabled(value)
        guard let app else { return }
        if value { app.cameraEnabled = true; Task { do { if !app.camera.running { try await app.camera.start(front: app.camera.front) } } catch { self.vision.setEnabled(false); self.message = "相机不可用，请检查权限" } } }
    }
    func cameraChanged() { vision.invalidate(); invalidateFollow("相机已变化，请重新选择目标") }
    func cameraRotated(clockwise turns: Int) {
        follow.rotateTarget(clockwise: turns)
        awaitingRotatedFrame = follow.target != nil
        // Keep target identity and reference through the forced companion rotation.
        // No command may use the old coordinate system; the ordinary 300 ms watchdog still applies.
    }
    private func detected(_ values: [Detection]) {
        if !follow.update(values, now: now) { invalidateFollow("目标丢失或存在歧义，请重新选择") }
        awaitingRotatedFrame = false
        let labels = Set(values.map(\.label))
        if labels != previousLabels && now - lastDetectionEvent >= 2 { previousLabels = labels; lastDetectionEvent = now; lifeEvent("visual_change"); record("visual_change", "count=\(values.count)") }
    }
    func invalidateFollow(_ reason: String) {
        let wasRunning = follow.enabled || followTask != nil
        followTask?.cancel(); followTask = nil; watchdog?.cancel(); watchdog = nil
        followOnStart = false; follow.invalidate(); followMessage = reason
        awaitingRotatedFrame = false
        let lease = followLease; followLease = nil
        if wasRunning { record("follow_stopped"); if let lease { app?.motion.stopCurrent(lease) } }
    }
    private func startFollow() {
        guard let app else { return }
        let token = generation
        record("follow_started"); followMessage = "正在跟随"
        // Independent watchdog does not wait behind an in-flight command ACK.
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled, token == self.generation, self.active else { return }
                if !self.follow.fresh(now: self.now) || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { self.invalidateFollow("检测过期或设备温度较高，跟随已停止"); return }
            }
        }
        followTask = Task { [weak self] in
            guard let self else { return }
            var lease: MotionLease?
            defer { if let lease { app.motion.release(lease) } }
            do {
                let acquired = try await app.motion.acquire(.follow); lease = acquired; self.followLease = acquired
                while !Task.isCancelled, token == self.generation, self.active, self.follow.enabled {
                    guard app.body.isConnected, app.settings.motionEnabled else { throw PolicyError.cancelled }
                    if self.awaitingRotatedFrame { try await Task.sleep(nanoseconds: 20_000_000); continue }
                    let intent = self.follow.intent(now: self.now)
                    guard self.follow.enabled else { throw PolicyError.cancelled }
                    _ = try await app.motion.send(["type": "motion", "linear": intent.linear, "angular": intent.angular, "duration_ms": 150, "ramp_ms": 0, "label": "vision_follow"], lease: acquired, timeout: 0.25)
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch {
                if token == self.generation && !Task.isCancelled { self.invalidateFollow("跟随指令失败，运动已停止"); app.settings.motionEnabled = false }
            }
        }
    }
    private func startPulse() {
        pulse?.cancel(); let token = generation
        pulse = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, token == self.generation, self.active else { return }
                self.tick(); self.refreshDiagnostics()
            }
        }
    }
    private var blocked: Bool {
        guard let app, active else { return true }
        let device = app.body.management
        return app.remote.presented || follow.enabled || followTask != nil || app.live.speaking || app.scenarioBusy || device.busy || device.info["ota_mode"] as? Bool == true || app.textBusy
    }
    private func tick() {
        guard let app, app.wake.phase != .suspended else { return }
        let previous = lifeState
        engine.tick(now: now, profile: profile, sleepAfter: behavior.sleepAfter); lifeState = engine.state
        if previous.mood != lifeState.mood || previous.sleeping != lifeState.sleeping { record("life_changed", lifeState.mood, decision: true) }
        let device = app.body.management
        let unavailable = app.remote.presented || follow.enabled || followTask != nil || app.scenarioBusy || device.busy || device.info["ota_mode"] as? Bool == true || app.textBusy || app.wake.phase == .connecting
        guard behavior.enabled, !unavailable, idleTask == nil else { return }
        if let scene = engine.select(now: now, catalog: catalog, settings: idleSettings, profile: profile,
                                     bodyAllowed: behavior.idleBody && app.settings.motionEnabled && allowsAutomaticBody,
                                     speaking: app.live.speaking, conversation: app.live.connected, gapMultiplier: behavior.idleGapMultiplier, sample: Double.random(in: 0..<1)) {
            execute(scene)
            if behavior.proactiveAI && (!wakeSettings.enabled || !app.settings.configuration.isLive || app.wake.mayUpload) { think(manual: false) }
        } else if engine.state.reason == "no_eligible_scene" && lifeState.reason != "no_eligible_scene" {
            app.face.neutralIdleExpression(); record("idle_empty", decision: true)
        }
    }
    func triggerRule() {
        guard let app, active, !app.remote.presented, !app.scenarioBusy, !follow.enabled, idleTask == nil,
              !app.body.management.busy, app.body.management.info["ota_mode"] as? Bool != true, app.wake.phase != .suspended else { return }
        if let scene = engine.select(now: now, catalog: catalog, settings: idleSettings, profile: profile,
                                     bodyAllowed: behavior.idleBody && app.settings.motionEnabled && allowsAutomaticBody,
                                     speaking: app.live.speaking, conversation: app.live.connected, manual: true, gapMultiplier: behavior.idleGapMultiplier, sample: Double.random(in: 0..<1)) { execute(scene) }
    }
    private func execute(_ scene: IdleScene) {
        guard let app else { return }
        let token = generation, taskID = UUID(); idleID = taskID; record("idle_scene", scene.id, decision: true)
        idleTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generation && taskID == self.idleID { self.idleTask = nil } }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.profile.reactionDelay * 1_000_000_000))
                guard !Task.isCancelled, token == self.generation, taskID == self.idleID, self.active else { return }
                try await app.runIdleScene(scene)
            } catch { self.record("rule_cancelled", decision: true) }
        }
    }
    func think(manual: Bool = true) {
        guard !blocked, (!wakeSettings.enabled || app?.settings.configuration.isLive != true || app?.wake.mayUpload == true), thought == nil, let app, !app.settings.configuration.isOffline else { message = "当前状态无法主动思考"; return }
        guard manual || behavior.proactiveAI else { return }
        guard scheduler.admitThought(now: now, limit: behavior.thoughtsPerMinute) else { message = "已达到主动思考频率限制"; return }
        let token = generation, requestToken = UUID(); thoughtGeneration = requestToken
        record("thought_requested", manual ? "manual" : "automatic", decision: true)
        thought = Task { [weak self] in
            guard let self else { return }
            defer { if requestToken == self.thoughtGeneration { self.thought = nil } }
            do {
                let context = "Companion idle event. Mood: \(self.lifeState.mood). Sleeping: \(self.lifeState.sleeping). Local objects: \(self.previousLabels.sorted().joined(separator: ",")). Suggest a brief optional expression and one allowed scene or null. Do not invent a user request."
                let raw = try await app.textRequest(context, allowActions: true, autonomous: true)
                guard !Task.isCancelled, token == self.generation, requestToken == self.thoughtGeneration, !self.blocked else { return }
                let result = KariAIRequest.companionReply(raw, allowedScenarios: app.scenarioNames)
                self.record("thought_completed", result.scenario ?? "no_action", decision: true)
                if let scene = result.scenario, self.behavior.idleBody, self.allowsAutomaticBody { try await app.runScenario(scene, source: .idle, allowBody: true) }
                guard !Task.isCancelled, requestToken == self.thoughtGeneration, !self.blocked else { return }
                if self.behavior.proactiveExpression && !result.text.isEmpty && self.scheduler.admitExpression(now: self.now, interval: self.behavior.expressionInterval / max(0.1, self.profile.coreTraits["talkativeness"] ?? 0.35)) {
                    if app.live.connected { app.live.sendText("Companion optional expression, not a user command. Say briefly in the current conversation language: " + result.text) }
                    else { app.textReply = result.text }
                }
            } catch { if requestToken == self.thoughtGeneration { self.record("thought_failed_rule_fallback", decision: true); self.triggerRule() } }
        }
    }
    func record(_ kind: String, _ detail: String = "", decision: Bool = false) { journal.record(kind, detail, now: now, decision: decision) }
    func refreshDiagnostics() {
        guard let app else { return }
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", ")
        diagnostics = ["会话": String(describing: app.phase), "Live": app.live.connected ? "connected" : "disconnected", "录音": String(app.live.microphone), "播放": String(app.live.speaking), "音频路由": route, "相机": String(app.camera.running), "检测耗时": String(format: "%.1f ms", vision.latencyMs), "检测数量": String(vision.detections.count), "跟随": String(follow.enabled), "运动来源": app.motion.source.map { String(describing: $0) } ?? "none", "视频帧数": String(app.live.sentVideoFrames), "音频块数": String(app.live.receivedAudioChunks), "待机": lifeState.sleeping ? "sleeping" : "awake"]
        diagnostics["生命状态"] = lifeState.mood
        diagnostics["注意力"] = lifeState.attention
        diagnostics["唤醒状态"] = app.wake.phase.rawValue
        diagnostics["唤醒次数"] = String(app.wake.wakeCount)
        diagnostics["唤醒缓冲溢出"] = String(app.wake.overflowCount)
        diagnostics["用户身份"] = lifeState.userIdentity
        diagnostics["距离"] = lifeState.userDistance
        diagnostics["障碍"] = lifeState.obstacle
        if let data = try? JSONSerialization.data(withJSONObject: app.live.audioDiagnostics.filter { $0.key != "route" }, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { diagnostics["音频缓冲"] = text }
        events = journal.events; decisions = journal.decisions
    }
    func clearJournal() { journal.clear(); refreshDiagnostics() }
    func diagnosticData() throws -> Data {
        refreshDiagnostics()
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "metrics": diagnostics, "events": journal.events.map { ["time": $0.time, "kind": $0.kind, "reason": $0.detail] as [String: Any] }, "decisions": journal.decisions.map { ["time": $0.time, "kind": $0.kind, "reason": $0.detail] as [String: Any] }], options: [.prettyPrinted, .sortedKeys])
    }
}

extension PolicyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidProfile: return L("人格或配置数据无效")
        case .cancelled: return L("动作已取消")
        case .busy: return L("控制来源优先级冲突")
        case .unconfirmed: return L("身体停止未获确认")
        }
    }
}
