import XCTest
import Foundation
import Security
@testable import KariNative
final class NativeRegressionTests: XCTestCase {
@MainActor func testNativeRegression() throws {

var passed = 0
func check(_ condition: Bool, _ name: String) {
    precondition(condition, name); passed += 1
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); preconditionFailure(name) } catch { passed += 1 }
}
var credentialServices: [String] = []
let legacyCredential = try KariKeychain.read("kari.gemini.key") { query in
    let service = query[kSecAttrService as String] as! String
    credentialServices.append(service)
    check(query[kSecAttrAccount as String] as? String == "kari.gemini.key", "credential fallback preserves provider account")
    return service == "app.kari.devfest.credentials" ? (errSecSuccess, Data("legacy-test-value".utf8)) : (errSecItemNotFound, nil)
}
check(legacyCredential == "legacy-test-value" && credentialServices == ["org.example.kari.credentials", "app.kari.devfest.credentials"], "personal build credentials remain readable")
credentialServices = []
let currentCredential = try KariKeychain.read("kari.gemini.key") { query in
    credentialServices.append(query[kSecAttrService as String] as! String)
    return (errSecSuccess, Data("current-test-value".utf8))
}
check(currentCredential == "current-test-value" && credentialServices.count == 1, "current credential takes precedence")
let missingCredential = try KariKeychain.read("kari.gemini.key") { _ in (errSecItemNotFound, nil) }
check(missingCredential.isEmpty, "missing credentials still require setup")
var lockedLookups = 0
rejects("locked keychain does not bypass access failure") {
    _ = try KariKeychain.read("kari.gemini.key") { _ in lockedLookups += 1; return (errSecInteractionNotAllowed, nil) }
}
check(lockedLookups == 1, "access failures do not fall back to old credentials")
var deletedServices: [String] = []
try KariKeychain.delete("kari.gemini.key") { query in
    deletedServices.append(query[kSecAttrService as String] as! String)
    return errSecItemNotFound
}
check(deletedServices == ["org.example.kari.credentials", "app.kari.devfest.credentials"], "deleting credentials also removes the fallback")
rejects("credential deletion failure is reported") { try KariKeychain.delete("kari.gemini.key") { _ in errSecAuthFailed } }
check(KariAIRequest.isStopRequest("请停下！"), "Mandarin immediate stop")
check(KariAIRequest.isStopRequest("stop moving"), "English immediate stop")
check(!KariAIRequest.isStopRequest("你好，今天天气如何"), "normal speech remains active")
let replyWithAction = KariAIRequest.companionReply("```json\n{\"text\":\"好呀\",\"scenario\":\"look_left\"}\n```", allowedScenarios:["look_left"])
check(replyWithAction.text == "好呀" && replyWithAction.scenario == "look_left", "native text action decodes known scenarios")
check(KariAIRequest.companionReply("{\"text\":\"你好\",\"scenario\":\"unsafe_custom_command\"}", allowedScenarios:["look_left"]).scenario == nil, "unknown text action cannot execute")
let motion = try KariBodyProtocol.validated(["type": "motion", "linear": 2.0, "angular": -3.0, "duration_ms": 20_000, "ramp_ms": 9999], motionAllowed: true)
check(motion["linear"] as? Double == 0.4 && motion["angular"] as? Double == -0.4, "bounded wheel speed")
check(motion["duration_ms"] as? Int == 1000 && motion["ramp_ms"] as? Int == 500, "bounded duration and ramp")
rejects("disarmed movement") { _ = try KariBodyProtocol.validated(["type":"motion", "linear":0.1, "angular":0.0], motionAllowed:false) }
rejects("NaN movement") { _ = try KariBodyProtocol.validated(["type":"motion", "linear":Double.nan, "angular":0.0], motionAllowed:true) }
rejects("unsupported command") { _ = try KariBodyProtocol.validated(["type":"flash_firmware"], motionAllowed:true) }
rejects("removed actuator command") { _ = try KariBodyProtocol.validated(["type":"unsupported_actuator"], motionAllowed:true) }
let stop = try KariBodyProtocol.packet(["type":"stop"], id:"stop-id")
check(stop.first == 10 && stop.last == 10, "stop separates unfinished BLE JSON")
var decoder = KariNotificationDecoder()
let ack = Data("{\"id\":\"same-id\",\"type\":\"ack\",\"label\":\"动作\"}\n".utf8)
let split = ack.count - 5
check(try decoder.append(Data(ack.prefix(split))).isEmpty, "fragment buffering")
let decoded = try decoder.append(Data(ack.suffix(ack.count - split)))
check(decoded.first?["label"] as? String == "动作", "split UTF8 preserved")
check(try decoder.append(Data("garbage\n{\"type\":\"pong\"}\n{\"type\":\"config\"}\n".utf8)).count == 2, "multiple notification frames")
rejects("oversized notification") { _ = try decoder.append(Data(repeating:65, count:65_537)) }
check(try decoder.append(Data("{\"type\":\"ack\"}\n".utf8)).count == 1, "decoder recovers after overflow")

let suite = "kari.native.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName:suite)!
defer { defaults.removePersistentDomain(forName:suite) }
let legacy: [String:Any] = ["selected":"gemini", "profiles":["gemini":["provider":"gemini", "mode":"live", "liveModel":"models/my-existing-model"]]]
defaults.set(String(data:try JSONSerialization.data(withJSONObject:legacy), encoding:.utf8), forKey:"CapacitorStorage.kari.providers.v1")
let settings = KariSettings(defaults:defaults)
check(settings.configuration.liveModel == "my-existing-model", "legacy custom live model preserved")
check(settings.configuration.model == "gemini-3.8-flash", "empty model gets provider default")
try settings.save(settings.configuration, key:"")
let restored = KariSettings(defaults:defaults)
check(restored.configuration.liveModel == "my-existing-model", "native preferences persist without keychain rewrite")
check(restored.motionEnabled == true, "companion motion is enabled by default")
for provider in KariProvider.all where !provider.models.isEmpty {
    let config = KariAIConfiguration.fresh(provider.id)
    check(config.model == provider.models.first, "default model \(provider.id)")
}
var gemini = KariAIConfiguration.fresh("gemini")
let request = try KariAIRequest.text(gemini, key:"test-key", prompt:"你好", image:Data([1,2]))
check(request.value(forHTTPHeaderField:"x-goog-api-key") == "test-key" && !request.url!.absoluteString.contains("test-key"), "key only in header")
let geminiBody = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
check((geminiBody["contents"] as! [[String:Any]]).count == 1, "native multimodal request")
var vertex = KariAIConfiguration.fresh("vertex"); vertex.projectId = "test-project"; vertex.region = "global"; vertex.auth = "oauth"
let vertexRequest = try KariAIRequest.text(vertex, key:"test-token", prompt:"hello")
check(vertexRequest.url!.host == "aiplatform.googleapis.com" && vertexRequest.value(forHTTPHeaderField:"Authorization") == "Bearer test-token", "Vertex global OAuth")
vertex.endpointType = "express"; vertex.auth = "apiKey"
check(try KariAIRequest.text(vertex,key:"test",prompt:"hello").url!.path.contains("publishers/google/models"), "express model path")
let qwen = try KariAIRequest.text(.fresh("qwen"), key:"test", prompt:"hello")
let qwenBody = try JSONSerialization.jsonObject(with:qwen.httpBody!) as! [String:Any]
check(qwenBody["enable_thinking"] as? Bool == false, "Qwen non-stream request disables thinking")
var ollama = KariAIConfiguration.fresh("ollama"); ollama.baseUrl = "http://192.168.1.5:11434"
check(try KariAIRequest.text(ollama,key:"",prompt:"hello").url!.path == "/api/chat", "Ollama native endpoint")
ollama.baseUrl = "http://example.com"
rejects("public cleartext credentials") { _ = try KariAIRequest.text(ollama,key:"",prompt:"hello") }
ollama.baseUrl = "http://10.example.com"
rejects("DNS name cannot masquerade as LAN IPv4") { _ = try KariAIRequest.text(ollama,key:"",prompt:"hello") }
let secret = "AI" + "zaExampleTestValue"
check(!KariAIRequest.redact(secret).contains(secret), "diagnostics redact Google keys")
check(!KariAIRequest.redact("Bearer test-token").contains("test-token"), "diagnostics redact tokens")
let response = try KariAIRequest.response(Data("{\"choices\":[{\"message\":{\"content\":\"你好\"}}]}".utf8),status:200,provider:"groq")
check(response == "你好", "compatible provider response")
rejects("failed request cannot pass") { _ = try KariAIRequest.response(Data("{}".utf8),status:403,provider:"gemini") }
// Burst delivery beyond the old 20-second cap must stay ordered while scheduling
// only 600 ms on the audio node. Completion and recovery must not leak requests.
var playback = KariPlaybackQueue()
let requestID = UUID()
let thirtySeconds = [Float](repeating: 0.25, count: 24_000 * 30)
check(playback.append(thirtySeconds, request: requestID), "30-second burst buffers without the old queue error")
let firstWindow = playback.takeWindow()
check(firstWindow.count == 3 && playback.scheduledFrames == 14_400, "only 600 ms scheduled")
check(firstWindow.allSatisfy { $0.samples.count <= 4_800 }, "large packets split into 200 ms slices")
check(playback.complete(firstWindow[0].id) == nil, "partial request cannot complete early")
let framesBeforeRecovery = playback.queuedFrames
playback.recover()
check(playback.queuedFrames == framesBeforeRecovery && playback.scheduledFrames == 0, "recovery preserves unplayed samples")
check(playback.complete(firstWindow[1].id) == nil && playback.queuedFrames == framesBeforeRecovery, "stale completion cannot drain recovered queue")
var window = playback.takeWindow()
check(window.first?.id != firstWindow[1].id && window.first?.samples == firstWindow[1].samples, "recovery replays unconfirmed audio with new IDs")
var completions: [UUID] = []
while !window.isEmpty {
    for chunk in window { if let id = playback.complete(chunk.id) { completions.append(id) } }
    window = playback.takeWindow()
}
check(playback.isEmpty && completions == [requestID], "burst drains with exactly one final completion")
let tinyID = UUID(), nextID = UUID()
check(playback.append([0.1], request: tinyID) && playback.append([0.2], request: nextID), "separate short requests accepted")
let tiny = playback.takeWindow()
check(tiny.map { $0.request } == [tinyID, nextID], "network packet ordering retained")
check(playback.complete(tiny[0].id) == tinyID && playback.complete(tiny[1].id) == nextID, "independent completion accounting")
check(!playback.canAppend(KariPlaybackQueue.capacity + 1), "memory remains bounded")
_ = playback.append([0.3], request: UUID()); let cancelled = playback.takeWindow(); playback.clear()
check(playback.complete(cancelled[0].id) == nil && playback.isEmpty, "late callback after stop is harmless")
var boundedPlayback = KariPlaybackQueue()
let fullID = UUID()
check(boundedPlayback.append([Float](repeating: 0, count: KariPlaybackQueue.capacity), request: fullID), "buffer accepts its capacity")
check(!boundedPlayback.append([1], request: UUID()) && boundedPlayback.queuedFrames == KariPlaybackQueue.capacity, "overflow leaves existing audio intact")
boundedPlayback.clear()
check(boundedPlayback.append([1], request: UUID()), "new speech accepted after clearing a failed turn")
let originalLive: [String: Any] = ["generationConfig": ["responseModalities": ["AUDIO"], "temperature": 0.7], "tools": [["name": "robot"]], "systemInstruction": ["parts": [["text": "companion"]]]]
let testLive = KariLiveConfiguration.setup(originalLive, model: "models/test", testOnly: true)
let testGeneration = testLive["generationConfig"] as! [String: Any]
check(testGeneration["maxOutputTokens"] as? Int == 256 && testGeneration["responseModalities"] as? [String] == ["AUDIO"], "AI test caps speech and preserves audio mode")
check((testLive["tools"] as? [Any])?.isEmpty == true && (testLive["sessionResumption"] as? [String: Any])?.isEmpty == true, "AI test isolates tools and previous conversation")
let regularLive = KariLiveConfiguration.setup(originalLive, model: "models/regular", testOnly: false)
check((regularLive["generationConfig"] as? [String: Any])?["maxOutputTokens"] == nil && (regularLive["tools"] as? [Any])?.count == 1, "normal companion retains original configuration")
check(KariLocalization.resolve(.system, preferred: ["zh-Hant-TW", "en-US"]) == "zh-Hans", "Chinese system locale resolves to Chinese")
check(KariLocalization.resolve(.system, preferred: ["en-GB", "zh-Hans"]) == "en", "English system locale resolves to English")
check(KariLocalization.resolve(.system, preferred: ["fr-FR"]) == "en", "unsupported interface language falls back to English")
check(KariLocalization.resolve(.chinese, preferred: ["en"]) == "zh-Hans", "explicit app language overrides system locale")
check(KariLocalization.string("退出陪伴", language: "en") == "Exit companion", "English localization resource is loaded")
check(KariLocalization.string("退出陪伴", language: "zh-Hans") == "退出陪伴", "Chinese source is retained")
check(KariLocalization.message("正在连接 我的桌面机器人…", language: "en") == "Connecting to 我的桌面机器人…", "dynamic robot name is never translated")
check(KariLocalization.message("实时连接中断：连接失败", language: "en") == "Live connection interrupted: Connection failed", "nested known runtime error is localized")
check(KariLocalization.message("播放恢复失败：custom server detail", language: "en") == "Playback recovery failed: custom server detail", "unknown error details remain intact")
let languageDefaults = UserDefaults(suiteName: "kari.language.tests.\(UUID().uuidString)")!
let languageStore = KariLocalization(defaults: languageDefaults)
languageStore.selection = .english
check(KariLocalization(defaults: languageDefaults).selection == .english, "language selection persists")
languageDefaults.removeObject(forKey: "kari.app.language")
let englishPolicy = KariConversationLanguage.instruction(fallback: "en")
let chinesePolicy = KariConversationLanguage.instruction(fallback: "zh-Hans")
check(englishPolicy.contains("latest spoken or typed message") && chinesePolicy.contains("latest spoken or typed message"), "user language wins in both UI languages")
check(englishPolicy.contains("explicitly requested") && englishPolicy.contains("every turn"), "explicit output-language requests and mid-session changes are supported")
check(englishPolicy.contains("English as the fallback") && chinesePolicy.contains("Simplified Chinese as the fallback"), "UI language is only a fallback")
check(KariConversationLanguage.offlineReply(to: "Hello, how are you today?", fallback: "zh-Hans").hasPrefix("Hello"), "offline English input wins over Chinese interface")
check(KariConversationLanguage.offlineReply(to: "你好，今天过得怎么样？", fallback: "en").hasPrefix("你好"), "offline Chinese input wins over English interface")
let multilingualLive: [String: Any] = ["generationConfig": ["speechConfig": ["languageCode": "zh-CN"]], "systemInstruction": ["parts": [["text": "Identity. <language_style>Always speak Mandarin.</language_style> Keep motion rules."]]]]
let multilingualSetup = KariLiveConfiguration.setup(multilingualLive, model: "models/test", testOnly: false)
let languageParts = (multilingualSetup["systemInstruction"] as! [String: Any])["parts"] as! [[String: Any]]
let liveInstruction = languageParts.compactMap { $0["text"] as? String }.joined()
check(!liveInstruction.contains("Always speak Mandarin") && liveInstruction.contains("Keep motion rules") && liveInstruction.contains("latest spoken"), "Live policy removes forced language and preserves safety rules")
check(((multilingualSetup["generationConfig"] as! [String: Any])["speechConfig"] as! [String: Any])["languageCode"] == nil, "Live speech language is not pinned to interface")
let separatedRequest = try KariAIRequest.text(gemini, key: "test-key", prompt: "Hello", systemInstruction: chinesePolicy)
let separatedBody = try JSONSerialization.jsonObject(with: separatedRequest.httpBody!) as! [String: Any]
check(separatedBody["systemInstruction"] != nil && (((separatedBody["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]])[0]["text"] as? String) == "Hello", "Gemini policy is separate from raw user text")
let separatedCompatible = try KariAIRequest.text(.fresh("qwen"), key: "test-key", prompt: "Hello", systemInstruction: chinesePolicy)
let separatedMessages = (try JSONSerialization.jsonObject(with: separatedCompatible.httpBody!) as! [String: Any])["messages"] as! [[String: Any]]
check(separatedMessages[0]["role"] as? String == "system" && separatedMessages[1]["content"] as? String == "Hello", "compatible providers receive system and user roles separately")
let firmwareDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let firmwareBytes = Data([0xe9] + Array(repeating: UInt8(0), count: 63))
let firmwareManifest: [String: Any] = ["version": "2.0.0", "chip": "ESP32-S3", "partition": "app3M_fat9M_16MB", "size": 64, "sha256": "27585a5e85e1a2afcb9718bcfd03a0fd8822b4cfdfd06862e3a2c0cfd1c092eb"]
var n8Manifest = firmwareManifest
n8Manifest["board"] = "n8r8"; n8Manifest["partition"] = "kari_8m"
try KariFirmwareCache.verify(firmwareBytes, manifest: n8Manifest)
n8Manifest["board"] = "n16r8"
rejects("8MB release cannot claim a 16MB board") { try KariFirmwareCache.verify(firmwareBytes, manifest: n8Manifest) }
let firmwareCache = KariFirmwareCache(directory: firmwareDirectory)
try firmwareCache.save(firmwareBytes, manifest: firmwareManifest)
check(try KariFirmwareCache(directory: firmwareDirectory).read()?.bytes == firmwareBytes, "verified firmware survives cache recreation without networking")
var corruptFirmware = firmwareBytes; corruptFirmware[3] = 1
rejects("bad download cannot replace prepared firmware") { try firmwareCache.save(corruptFirmware, manifest: firmwareManifest) }
check(try firmwareCache.read()?.bytes == firmwareBytes, "failed download preserves prepared package")
try corruptFirmware.write(to: firmwareDirectory.appendingPathComponent("27585a5e85e1a2afcb9718bcfd03a0fd8822b4cfdfd06862e3a2c0cfd1c092eb.bin"))
rejects("corrupted cached image is rejected before upload") { _ = try firmwareCache.read() }
try FileManager.default.removeItem(at: firmwareDirectory)

check(KariFirmwareCache.allowsUpdate([:]), "legacy packages use stable channel")
check(!KariFirmwareCache.allowsUpdate(["channel":"preview"]), "preview packages require explicit opt-in")
check(KariFirmwareCache.allowsUpdate(["channel":"preview"], includePreview:true), "preview opt-in allows matching cached preview")
check(!KariFirmwareCache.allowsUpdate(["channel":"unknown"], includePreview:true), "unknown update channels rejected")
print("Native Swift checks passed: \(passed)")

assert(kariCompareVersions("2.2.0", "2.1.0") > 0)
assert(kariCompareVersions("2.10.0", "2.9.9") > 0)
assert(kariCompareVersions("2.2.0", "2.2.0") == 0)
assert(kariCompareVersions("2.3.0-beta.2", "2.3.0-beta.10") < 0)
assert(kariCompareVersions("2.3.0", "2.3.0-rc.1") > 0)
assert(kariCompareVersions("2.3.0-beta", "2.3.0-alpha") > 0)
assert(kariCompareVersions("2.3.0+old", "2.3.0+new") == 0)
assert(kariCompareVersions("v2.2.0", "2.2.0") == 0)
assert(kariCompareVersions("2.3.0-beta", "2.2.9") > 0)
assert(kariCompareVersions("2.3.0-1", "2.3.0-alpha") < 0)
assert(kariCompareVersions("2.3.0-beta", "2.3.0-beta.1") < 0)

assert(KariDeviceReadiness.blockReason(["ota_mode": true, "hardware_ready": true])?.contains("升级模式") == true)
assert(KariDeviceReadiness.blockReason(["ota_mode": false, "hardware_ready": false, "hardware_error": "Physical Flash/PSRAM mismatch; motors disabled"])?.contains("板型") == true)
assert(KariDeviceReadiness.blockReason(["hardware_ready": true]) == nil)
assert(KariDeviceReadiness.blockReason([:]) == nil) // legacy firmware has no hardware flag
assert(KariDeviceReadiness.localizedReason("Device administrator password required").contains("管理密码"))

let missingWiring: [String: Any] = ["hardware_configured": false, "hardware_profile": ["board": "n16r8"]]
assert((KariDeviceReadiness.defaultWiringRepair(missingWiring)?["pins"] as? [String: Int])?["ena"] == 17)
assert(KariDeviceReadiness.defaultWiringRepair(["hardware_configured": true, "hardware_profile": ["board": "n16r8"]]) == nil)
assert(KariDeviceReadiness.defaultWiringRepair(["hardware_configured": false, "hardware_profile": ["board": "unknown"]]) == nil)
assert(KariDeviceReadiness.defaultWiringRepair([:]) == nil)
}
}
