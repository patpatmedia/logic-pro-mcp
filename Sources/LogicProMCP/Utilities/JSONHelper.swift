import Foundation

/// Render a Swift string as a JSON string literal, quotes included.
/// Needed wherever JSON is assembled by hand: project and track names come from the user
/// and a single `"` in one of them used to produce invalid JSON.
func jsonString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

/// Encode any Codable value to a pretty-printed JSON string for MCP tool responses.
func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value),
          let string = String(data: data, encoding: .utf8) else {
        return "{\"error\": \"Failed to encode response\"}"
    }
    return string
}
