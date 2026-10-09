import Foundation

func jsonObject(from line: String) -> [String: Any]? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func nonemptyString(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// JSON `true` / `false` only. A numeric `1` is not a boolean.
func jsonBool(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return false
    }
    return number.boolValue
}

enum JSONID: Equatable, Sendable {
    case number(Int)
    case string(String)

    var jsonValue: Any {
        switch self {
        case .number(let value): value
        case .string(let value): value
        }
    }
}

func jsonID(_ value: Any?) -> JSONID? {
    guard let value, !(value is NSNull) else { return nil }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        return .number(number.intValue)
    }
    if let text = value as? String, !text.isEmpty {
        return .string(text)
    }
    return nil
}

func jsonLine(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else {
        return ""
    }
    return text
}
