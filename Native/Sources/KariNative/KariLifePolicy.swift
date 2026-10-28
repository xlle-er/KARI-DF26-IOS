import Foundation

struct IdleScene: Codable, Identifiable, Equatable {
    struct Step: Codable, Equatable {
        var kind: String
        var left: Double?
        var right: Double?
        var durationMs: Double?
        var pauseMs: Double?
    }
    var id: String
    var title: String
    var titleZH: String
    var body: Bool
    var pose: String?
    var steps: [Step]
    static func load() -> [Self] {
        guard let url = Bundle.module.url(forResource: "IdleScenes", withExtension: "json"),
              let data = try? Data(contentsOf: url), let scenes = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return scenes
    }
}

enum IdleAvailability: String, Codable, CaseIterable { case always, awake, sleeping }
struct IdleSceneOptions: Codable, Equatable {
    var enabled = true
    var weight = 1.0
    var cooldown = 30.0
    var availability = IdleAvailability.always
    var speedScale = 1.0
    var durationScale = 1.0
    func validate() throws {
        guard weight.isFinite, (0...10).contains(weight), cooldown.isFinite, (0...600).contains(cooldown),
              speedScale.isFinite, (0.25...1.5).contains(speedScale), durationScale.isFinite, (0.5...2).contains(durationScale) else { throw PolicyError.invalidProfile }
    }
}
struct IdleInterval: Codable, Equatable {
    var minimum: Double
    var maximum: Double
    func validate() throws {
        guard minimum.isFinite, maximum.isFinite, (3...300).contains(minimum), (minimum...600).contains(maximum) else { throw PolicyError.invalidProfile }
    }
    func value(_ sample: Double) -> Double { minimum + (maximum - minimum) * min(1, max(0, sample)) }
}
struct IdleSceneSettings: Codable, Equatable {
    var first = IdleInterval(minimum: 8, maximum: 15)
    var silent = IdleInterval(minimum: 15, maximum: 30)
    var conversation = IdleInterval(minimum: 20, maximum: 40)
    var speedScale = 1.0
    var durationScale = 1.0
    var repeatGap = 15.0
    var scenes: [String: IdleSceneOptions] = [:]
    func options(_ id: String) -> IdleSceneOptions { scenes[id] ?? IdleSceneOptions() }
    func validate(known: Set<String>) throws {
        try first.validate(); try silent.validate(); try conversation.validate()
        guard speedScale.isFinite, (0.25...1.5).contains(speedScale), durationScale.isFinite, (0.5...2).contains(durationScale), repeatGap.isFinite, (0...600).contains(repeatGap), Set(scenes.keys).isSubset(of: known) else { throw PolicyError.invalidProfile }
        for value in scenes.values { try value.validate() }
    }
}

struct LifeState: Equatable {
    var energy = 0.75
    var boredom = 0.2
    var curiosity = 0.6
    var affection = 0.5
    var loneliness = 0.1
    var comfort = 0.6
    var mood = "neutral"
    var attention = "none"
    var sleeping = false
    var speaking = false
    var moving = false
    var reason = "session_started"
    // Object detection cannot identify a user or measure their distance.
    let userIdentity = "unknown"
    let userDistance = "unknown"
    let obstacle = "unknown"
}
struct LifeEngine {
    private(set) var state = LifeState()
    private var previous: Double?
    private var suspendedAt: Double?
    private var lastInteraction = 0.0
    private var nextScene = 0.0
    private var lastScene: String?
    private var lastSceneAt = -Double.infinity
    private var executions: [String: Double] = [:]
    mutating func begin(now: Double, settings: IdleSceneSettings, sample: Double = 0.5) {
        state = LifeState(); suspendedAt = nil; previous = now; lastInteraction = now
        nextScene = now + settings.first.value(sample); lastScene = nil; lastSceneAt = -.infinity; executions = [:]
    }
    mutating func suspend() { suspendedAt = previous; previous = nil }
    mutating func event(_ kind: String, now: Double) {
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        switch kind {
        case "user_activity", "wake":
            lastInteraction = now; state.sleeping = false; state.attention = "interaction"
            state.boredom = 0; state.loneliness = clamp(state.loneliness - 0.08)
            state.comfort = clamp(state.comfort + 0.04); state.affection = clamp(state.affection + 0.02)
            state.curiosity = clamp(state.curiosity + 0.05)
        case "visual_change": state.curiosity = clamp(state.curiosity + 0.02)
        case "playback_started": state.speaking = true
        case "playback_stopped": state.speaking = false
        case "motion_started": state.moving = true
        case "motion_stopped": state.moving = false
        case "disconnected": state.moving = false
        default: break
        }
        state.reason = kind
    }
    mutating func tick(now: Double, profile: PersonalityProfile, sleepAfter: Double) {
        guard let previous else {
            if let suspendedAt {
                let pause = max(0, now - suspendedAt)
                lastInteraction += pause; nextScene += pause
                if lastSceneAt.isFinite { lastSceneAt += pause }
                executions = executions.mapValues { $0 + pause }
            }
            suspendedAt = nil; self.previous = now; return
        }
        // Drive rates are the Web 500ms rates converted to seconds. Bound stalls;
        // suspension clears the clock so background time never changes state.
        let dt = min(2, max(0, now - previous)); self.previous = now
        let idle = now - lastInteraction
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        state.boredom = clamp(state.boredom + (idle > 15 ? (0.006 + (profile.behaviorStyle["idleActivity"] ?? 0.35) * 0.012) * 2 : -0.06) * dt)
        if idle > 8 { state.curiosity = clamp(state.curiosity + (0.002 + (profile.coreTraits["curiosity"] ?? 0.75) * 0.004) * 2 * dt) }
        state.loneliness = clamp(state.loneliness + (idle > 30 ? (0.003 + (1 - (profile.coreTraits["independence"] ?? 0.45)) * 0.006) * 2 : -0.008) * dt)
        if idle > 30 { state.comfort = clamp(state.comfort - 0.004 * dt) }
        state.energy = clamp(state.energy + (state.sleeping ? 0.004 : state.moving ? -0.01 : -0.001) * dt)
        state.sleeping = idle >= sleepAfter
        state.mood = state.sleeping || state.energy < 0.2 ? "sleepy" : idle < 2.5 ? "attentive" : state.boredom > 0.7 || state.loneliness > 0.72 ? "curious" : "neutral"
        state.attention = state.sleeping ? "resting" : idle < 8 ? "interaction" : "surroundings"
    }
    mutating func select(now: Double, catalog: [IdleScene], settings: IdleSceneSettings, profile: PersonalityProfile, bodyAllowed: Bool, speaking: Bool, conversation: Bool, manual: Bool = false, gapMultiplier: Double = 1, sample: Double) -> IdleScene? {
        guard manual || now >= nextScene, now - lastInteraction >= 3 else { return nil }
        let interval = conversation ? settings.conversation : settings.silent
        nextScene = now + interval.value(sample) * max(0.25, profile.idleGap / 20) * gapMultiplier
        let candidates = catalog.filter { scene in
            let option = settings.options(scene.id)
            return option.enabled && option.weight > 0 && (!scene.body || bodyAllowed && !speaking && !state.sleeping)
                && (option.availability == .always || option.availability == .sleeping && state.sleeping || option.availability == .awake && !state.sleeping)
                && now - (executions[scene.id] ?? -.infinity) >= option.cooldown
                && (scene.id != lastScene || now - lastSceneAt >= settings.repeatGap)
        }
        func weight(_ scene: IdleScene) -> Double {
            let affinity = scene.pose == "pose_" + state.mood ? 2.0 : 1.0
            let personality = scene.pose == "pose_happy" ? 0.5 + (profile.coreTraits["playfulness"] ?? 0.55) : scene.pose == "pose_curious" ? 0.5 + state.curiosity : 1
            let expression = profile.behaviorStyle["emotionalExpressiveness"] ?? 0.65
            let emotionalWeight = scene.pose == "pose_neutral" ? 1.5 - expression : scene.body ? 1 : max(0.05, expression)
            return settings.options(scene.id).weight * affinity * personality * emotionalWeight
        }
        let total = candidates.reduce(0.0) { $0 + weight($1) }
        guard total > 0 else { state.reason = "no_eligible_scene"; return nil }
        var pick = min(0.999999, max(0, sample)) * total
        let chosen = candidates.first { scene in pick -= weight(scene); return pick < 0 } ?? candidates.last!
        executions[chosen.id] = now; lastScene = chosen.id; lastSceneAt = now; state.reason = chosen.id
        return chosen
    }
}

enum WakePreset: String, Codable, CaseIterable {
    case chinese, english
    var locale: String { self == .chinese ? "zh-CN" : "en-US" }
    var title: String { self == .chinese ? "你好卡里" : "Hey KARI" }
    func matches(_ text: String) -> Bool {
        let normalized = text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.map(String.init).joined()
        let phrases = self == .chinese ? ["你好卡里", "你好kari"] : ["heykari"]
        return phrases.contains { normalized.hasPrefix($0) }
    }
}
struct WakeSettings: Codable, Equatable {
    var enabled = false
    var preset = WakePreset.chinese
    var silenceTimeout = 60.0
    func validate() throws { guard silenceTimeout.isFinite, (30...300).contains(silenceTimeout) else { throw PolicyError.invalidProfile } }
}
enum WakePhase: String { case stopped, waiting, connecting, conversation, suspended }
// This policy owns all buffering and transition gates; no audio survives a stop.
struct WakePolicy {
    private(set) var phase = WakePhase.stopped
    private(set) var buffer = Data()
    private(set) var overflow = false
    private(set) var lastActivity = 0.0
    private(set) var generation = 0
    private(set) var lastWake = -Double.infinity
    mutating func wait(now: Double) { generation += 1; phase = .waiting; buffer.removeAll(); overflow = false; lastActivity = now }
    @discardableResult mutating func wake(now: Double) -> Int? {
        guard phase == .waiting, now - lastWake >= 2 else { return nil }
        phase = .connecting; lastWake = now; lastActivity = now; return generation
    }
    mutating func append(_ pcm: Data, now: Double, voice: Bool) -> Data? {
        if voice { lastActivity = now }
        switch phase {
        case .waiting:
            buffer.append(pcm); if buffer.count > 32_000 { buffer.removeFirst(buffer.count - 32_000) }
        case .connecting:
            if !overflow { if buffer.count + pcm.count > 256_000 { buffer.removeAll(); overflow = true } else { buffer.append(pcm) } }
        case .conversation: return pcm
        default: break
        }
        return nil
    }
    mutating func connected(generation: Int, now: Double) -> Data? {
        guard phase == .connecting, generation == self.generation else { return nil }
        phase = .conversation; lastActivity = now
        let result = buffer; buffer.removeAll(); return result
    }
    mutating func activity(now: Double) { lastActivity = now }
    func timedOut(now: Double, timeout: Double, busy: Bool) -> Bool { phase == .conversation && !busy && now - lastActivity >= timeout }
    mutating func stop(suspended: Bool = false) { generation += 1; phase = suspended ? .suspended : .stopped; buffer.removeAll(); overflow = false }
}
struct CompanionConfiguration: Codable {
    var schemaVersion = 1
    var profile: PersonalityProfile
    var behavior: BehaviorSettings
    var idle: IdleSceneSettings
    var wake: WakeSettings
    func validated(knownScenes: Set<String>) throws -> Self {
        guard schemaVersion == 1 else { throw PolicyError.invalidProfile }
        var copy = self
        copy.profile = try PersonalityProfile.imported(profile.exported())
        var normalized = behavior; normalized.normalize()
        guard normalized == behavior else { throw PolicyError.invalidProfile }
        try idle.validate(known: knownScenes); try wake.validate()
        return copy
    }
}
