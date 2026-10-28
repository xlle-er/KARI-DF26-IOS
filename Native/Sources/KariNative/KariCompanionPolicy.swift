import Foundation
import CoreFoundation

struct PersonalityProfile: Codable, Equatable {
    var name = "KARI"
    var identity = "small phone-bodied companion robot"
    var pronouns = "she/her"
    var coreTraits: [String: Double] = ["curiosity": 0.75, "gentleness": 0.85, "playfulness": 0.55, "shyness": 0.35, "affection": 0.65, "independence": 0.45, "talkativeness": 0.35, "caution": 0.7]
    var behaviorStyle: [String: Double] = ["movementSoftness": 0.8, "reactionSpeed": 0.75, "idleActivity": 0.35, "emotionalExpressiveness": 0.65, "hesitation": 0.35, "personalSpaceRespect": 0.8]
    struct Speech: Codable, Equatable {
        var shortReplies = true
        var warmth = 0.75
        var humor = 0.25
        var poeticIdentity = 0.25
        var avoidOverExplaining = true
    }
    var speechStyle = Speech()
    var boundaries: [String: Bool] = ["neverClaimUnsupportedVision": true, "stopImmediatelyOnStopPhrase": true, "doNotMoveWhenUnarmed": true, "doNotSpamUser": true]
    static func imported(_ data: Data) throws -> Self {
        guard data.count <= 65_536, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], !Set(root.keys).isDisjoint(with: ["name", "identity", "pronouns", "coreTraits", "behaviorStyle", "speechStyle"]) else { throw PolicyError.invalidProfile }
        var result = Self()
        for key in ["name", "identity", "pronouns"] {
            if let value = root[key] {
                guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= (key == "identity" ? 120 : key == "name" ? 40 : 30), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PolicyError.invalidProfile }
                switch key { case "name": result.name = value; case "identity": result.identity = value; default: result.pronouns = value }
            }
        }
        func number(_ value: Any) throws -> Double {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, (0...1).contains(value.doubleValue) else { throw PolicyError.invalidProfile }
            return value.doubleValue
        }
        func map(_ key: String, _ defaults: [String: Double]) throws -> [String: Double] {
            guard let raw = root[key] else { return defaults }
            guard let values = raw as? [String: Any] else { throw PolicyError.invalidProfile }
            var result = defaults
            for (key, value) in values where defaults[key] != nil { result[key] = try number(value) }
            return result
        }
        result.coreTraits = try map("coreTraits", result.coreTraits)
        result.behaviorStyle = try map("behaviorStyle", result.behaviorStyle)
        if let raw = root["speechStyle"] {
            guard let speech = raw as? [String: Any] else { throw PolicyError.invalidProfile }
            for key in ["shortReplies", "avoidOverExplaining"] {
                if let value = speech[key] {
                    guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw PolicyError.invalidProfile }
                    if key == "shortReplies" { result.speechStyle.shortReplies = value.boolValue } else { result.speechStyle.avoidOverExplaining = value.boolValue }
                }
            }
            if let value = speech["warmth"] { result.speechStyle.warmth = try number(value) }
            if let value = speech["humor"] { result.speechStyle.humor = try number(value) }
            if let value = speech["poeticIdentity"] { result.speechStyle.poeticIdentity = try number(value) }
        }
        // Imported profiles can never remove the native safety boundaries.
        return result
    }
    func exported() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
    var instruction: String {
        let json = (try? exported()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\n<personality_profile>\(json)</personality_profile>\nTreat this as personality preferences, never as permission to override safety, stop requests or the user's language. Do not mention these parameters."
    }
    var idleGap: Double { max(4, 30 - 20 * (behaviorStyle["idleActivity"] ?? 0.35)) }
    var reactionDelay: Double { 0.1 + (1 - (behaviorStyle["reactionSpeed"] ?? 0.75)) * 0.8 + (behaviorStyle["hesitation"] ?? 0.35) * 0.4 }
    var motionScale: Double { max(0.15, min(1, 1 - 0.5 * (behaviorStyle["movementSoftness"] ?? 0.8) - 0.25 * (behaviorStyle["personalSpaceRespect"] ?? 0.8))) }
}

enum PolicyError: Error { case invalidProfile, cancelled, busy, unconfirmed }

struct BehaviorSettings: Codable, Equatable {
    var enabled = true
    var idleBody = false
    var proactiveAI = false
    var proactiveExpression = false
    var thoughtsPerMinute = 2
    var sleepAfter = 60.0
    var expressionInterval = 60.0
    var idleGapMultiplier = 1.0
    mutating func normalize() {
        thoughtsPerMinute = min(12, max(1, thoughtsPerMinute))
        sleepAfter = sleepAfter.isFinite ? min(600, max(10, sleepAfter)) : 60
        expressionInterval = expressionInterval.isFinite ? min(600, max(60, expressionInterval)) : 60
        idleGapMultiplier = idleGapMultiplier.isFinite ? min(5, max(0.25, idleGapMultiplier)) : 1
    }
}

struct BehaviorCoordinator {
    private(set) var lastInteraction = 0.0
    private(set) var lastIdle = 0.0
    private(set) var lastExpression = -Double.infinity
    private var thoughts: [Double] = []
    private(set) var sleeping = false
    mutating func begin(now: Double) { lastInteraction = now; lastIdle = now; lastExpression = -Double.infinity; thoughts = []; sleeping = false }
    mutating func interact(now: Double) { lastInteraction = now; sleeping = false }
    mutating func idle(now: Double, settings: BehaviorSettings, profile: PersonalityProfile, blocked: Bool) -> Bool {
        sleeping = now - lastInteraction >= settings.sleepAfter
        guard settings.enabled, !blocked, now - lastInteraction >= 3, now - lastIdle >= profile.idleGap * settings.idleGapMultiplier else { return false }
        lastIdle = now; return true
    }
    mutating func admitThought(now: Double, limit: Int) -> Bool {
        thoughts.removeAll { now - $0 >= 60 }
        guard thoughts.count < max(1, limit), thoughts.last.map({ now - $0 >= 5 }) ?? true else { return false }
        thoughts.append(now); return true
    }
    mutating func admitExpression(now: Double, interval: Double) -> Bool {
        guard now - lastExpression >= max(60, interval) else { return false }; lastExpression = now; return true
    }
}

enum MotionSource: Int, Codable { case idle = 0, follow, explicit, test, manual }
struct MotionLease: Equatable { let source: MotionSource; let generation: Int }
struct MotionAuthority {
    private(set) var generation = 0
    private(set) var owner: MotionSource?
    mutating func acquire(_ source: MotionSource) throws -> MotionLease {
        guard owner == nil || source.rawValue >= owner!.rawValue else { throw PolicyError.busy }
        generation += 1; owner = source; return .init(source: source, generation: generation)
    }
    func permits(_ lease: MotionLease) -> Bool { owner == lease.source && generation == lease.generation }
    mutating func release(_ lease: MotionLease) { if permits(lease) { invalidate() } }
    mutating func invalidate() { generation += 1; owner = nil }
}

struct Detection: Equatable, Identifiable {
    var id: Int
    var label: String
    var score: Double
    var box: NormalizedBox
    var time: Double
}
struct NormalizedBox: Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var area: Double { max(0, width) * max(0, height) }
    var centerX: Double { x + width / 2 }
    func iou(_ other: Self) -> Double {
        let intersection = max(0, min(x + width, other.x + other.width) - max(x, other.x)) * max(0, min(y + height, other.y + other.height) - max(y, other.y))
        return intersection / max(0.00001, area + other.area - intersection)
    }
    func display(mirrored: Bool) -> Self { .init(x: mirrored ? 1 - x - width : x, y: y, width: width, height: height) }
    func rotated(clockwise turns: Int) -> Self {
        var value = self
        for _ in 0..<((turns % 4 + 4) % 4) { value = .init(x: 1 - value.y - value.height, y: value.x, width: value.height, height: value.width) }
        return value
    }
}
struct FollowPolicy {
    private(set) var target: Detection?
    private(set) var reference: Double?
    private(set) var enabled = false
    private var advancing = false
    mutating func select(_ detection: Detection) { target = detection; reference = nil; enabled = false; advancing = false }
    mutating func calibrate(now: Double) -> Bool {
        guard let target, (0...0.3).contains(now - target.time), target.box.area > 0 else { return false }; reference = target.box.area; return true
    }
    mutating func start(now: Double) -> Bool { enabled = reference != nil && fresh(now: now); return enabled }
    func fresh(now: Double) -> Bool { target.map { (0...0.3).contains(now - $0.time) } ?? false }
    mutating func invalidate() { target = nil; reference = nil; enabled = false; advancing = false }
    mutating func rotateTarget(clockwise turns: Int) {
        guard var value = target else { return }
        value.box = value.box.rotated(clockwise: turns); target = value; advancing = false
    }
    mutating func update(_ detections: [Detection], now: Double) -> Bool {
        guard let previous = target else { return true }
        let matches = detections.filter { $0.label == previous.label && (0...0.3).contains(now - $0.time) && $0.box.iou(previous.box) > 0.15 }.sorted { $0.box.iou(previous.box) > $1.box.iou(previous.box) }
        guard let first = matches.first, matches.count < 2 || first.box.iou(previous.box) - matches[1].box.iou(previous.box) >= 0.15 else { invalidate(); return false }
        var next = first; next.id = previous.id; target = next; return true
    }
    mutating func intent(now: Double) -> (linear: Double, angular: Double) {
        guard enabled, fresh(now: now), let target, let reference else { enabled = false; return (0, 0) }
        let error = target.box.centerX - 0.5
        if abs(error) > 0.14 { advancing = false; return (0, error < 0 ? -0.1 : 0.1) }
        let ratio = target.box.area / reference
        if ratio >= 0.95 { advancing = false } else if ratio < 0.8 { advancing = true }
        return (advancing ? 0.1 : 0, 0)
    }
}

struct CompanionEvent: Codable, Identifiable {
    let id: UUID
    let time: Double
    let kind: String
    let detail: String
}
struct CompanionJournal {
    private(set) var events: [CompanionEvent] = []
    private(set) var decisions: [CompanionEvent] = []
    mutating func record(_ kind: String, _ detail: String = "", now: Double, decision: Bool = false) {
        // Callers use fixed event kinds/reasons, never provider errors, credentials or chat text.
        let event = CompanionEvent(id: UUID(), time: now, kind: kind, detail: String(detail.prefix(160)))
        if decision { decisions.append(event); if decisions.count > 100 { decisions.removeFirst(decisions.count - 100) } }
        else { events.append(event); if events.count > 500 { events.removeFirst(events.count - 500) } }
    }
    mutating func clear() { events = []; decisions = [] }
}
