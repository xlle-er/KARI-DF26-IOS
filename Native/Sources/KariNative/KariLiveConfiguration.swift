import Foundation

enum KariLiveConfiguration {
    static func setup(_ original: [String: Any], model: String, testOnly: Bool) -> [String: Any] {
        var payload = original
        payload["model"] = model
        let language = KariLocalization.shared.language
        let policy = KariConversationLanguage.instruction(fallback: language)
        let originalParts = (payload["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var parts = originalParts.map { part -> [String: Any] in
            var result = part
            if let text = part["text"] as? String {
                result["text"] = text.replacingOccurrences(of: "(?s)<language_style>.*?</language_style>", with: "", options: .regularExpression)
            }
            return result
        }
        parts.append(["text": policy]); payload["systemInstruction"] = ["parts": parts]
        // Keep automatic speech-language detection; never pin speech to UI language.
        if var generation = payload["generationConfig"] as? [String: Any], var speech = generation["speechConfig"] as? [String: Any] {
            speech.removeValue(forKey: "languageCode"); generation["speechConfig"] = speech; payload["generationConfig"] = generation
        }
        // Keep intentional barge-in, but require a clearer speech onset so the
        // loudspeaker tail and short room noises do not repeatedly cancel speech.
        var realtime = payload["realtimeInputConfig"] as? [String: Any] ?? [:]
        realtime["automaticActivityDetection"] = [
            "disabled": false,
            "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
            "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
            "prefixPaddingMs": 300,
            "silenceDurationMs": 700
        ]
        payload["realtimeInputConfig"] = realtime
        if testOnly {
            payload["tools"] = []
            payload["systemInstruction"] = ["parts": [["text": "This is a speaker connectivity test. Say the exact sentence requested by the user once, then finish immediately. Do not explain or call tools. " + policy]]]
            var generation = payload["generationConfig"] as? [String: Any] ?? [:]
            generation["maxOutputTokens"] = 256
            payload["generationConfig"] = generation
            payload["sessionResumption"] = [:]
        }
        return payload
    }
}
