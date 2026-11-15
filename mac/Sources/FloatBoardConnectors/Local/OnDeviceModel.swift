import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "On this Mac" as the model for judging messages (Mac only mode; docs/architecture.md, Edition 2, C7): Apple's
/// on-device model, free and private, less accurate than Claude. The engine inside the app asks for it like any model
/// (a Claude-style request with model "on-device"); `LocalMode` hands those requests here instead of the network, and
/// the answer comes back in the same shape as Claude's.
public enum OnDeviceModel {
    public static let modelID = "on-device"
    /// The model's context is small: longer messages are cut to this many characters.
    static let maxText = 6000
    /// Checks replace the model.
    nonisolated(unsafe) public static var answerOverride: ((_ instructions: String, _ prompt: String) async throws -> String)?

    /// True when this Mac has Apple's on-device model ready (Apple Intelligence on, model downloaded).
    public static var isAvailable: Bool {
        if answerOverride != nil { return true }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// True when a Claude-style request body asks for the on-device model.
    public static func wants(_ body: Data?) -> Bool {
        guard let body, let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false } // try?-ok: not JSON means not for us
        return o["model"] as? String == modelID
    }

    /// Answers a Claude-style request body with the on-device model, as Claude's response JSON.
    public static func answer(_ body: Data) async throws -> Data {
        guard let o = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        func text(_ v: Any?) -> String {
            if let s = v as? String { return s }
            return (v as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        let system = text(o["system"])
        let user = String(text((o["messages"] as? [[String: Any]])?.first?["content"]).prefix(maxText))
        var instructions = system
        if let schema = ((o["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"],
           let s = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) { // try?-ok: without the schema the answer is still JSON-checked by the engine
            instructions += "\n\nAnswer with one JSON object only, no other text, matching this JSON schema:\n" + String(decoding: s, as: UTF8.self)
        }
        let raw = try await respond(instructions: instructions, prompt: user)
        let json = extractJSON(raw)
        let out: [String: Any] = ["id": "ondevice", "type": "message", "role": "assistant", "model": modelID, "stop_reason": "end_turn",
                                  "stop_sequence": NSNull(), "content": [["type": "text", "text": json]],
                                  "usage": ["input_tokens": 0, "output_tokens": 0]]
        return try JSONSerialization.data(withJSONObject: out)
    }

    /// The first {...} in the answer (the model sometimes wraps it in a code fence); the whole answer when there is none.
    static func extractJSON(_ s: String) -> String {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return s }
        return String(s[a...b])
    }

    private static func respond(instructions: String, prompt: String) async throws -> String {
        if let answerOverride { return try await answerOverride(instructions, prompt) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw URLError(.unsupportedURL)
    }
}
