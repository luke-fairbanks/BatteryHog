import Foundation

/// English source phrases are stable keys shared with the WebKit dashboard.
/// Locale preferences include macOS's per-application language override.
enum Localization {
    static func language(for preferences: [String]) -> String {
        for preference in preferences {
            let tag = preference.replacingOccurrences(of: "_", with: "-").lowercased()
            if tag == "en" || tag.hasPrefix("en-") { return "en" }
            if tag == "zh" || tag == "zh-cn" || tag == "zh-sg" || tag.hasPrefix("zh-hans") {
                return "zh-Hans"
            }
        }
        return "en"
    }

    static let currentLanguage = language(for: Locale.preferredLanguages)
    private enum Message: Decodable {
        case text(String)
        case plural([String: String])
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { self = .text(text) }
            else { self = .plural(try container.decode([String: String].self)) }
        }
        func value(count: String?) -> String {
            switch self {
            case .text(let text): return text
            case .plural(let forms):
                // English uses one/other; Simplified Chinese uses other.
                let category = currentLanguage == "en" && Double(count ?? "") == 1 ? "one" : "other"
                return forms[category] ?? forms["other"] ?? ""
            }
        }
    }
    private static let catalogs: [String: [String: Message]] = {
        var result = [String: [String: Message]]()
        for language in ["en", currentLanguage] {
            guard let url = Bundle.main.resourceURL?
                .appendingPathComponent("locales/\(language).json"),
                  let data = try? Data(contentsOf: url),
                  let strings = try? JSONDecoder().decode([String: Message].self, from: data)
            else { continue }
            result[language] = strings
        }
        return result
    }()

    static func text(_ key: String, _ values: [String: String] = [:]) -> String {
        let message = catalogs[currentLanguage]?[key] ?? catalogs["en"]?[key]
        return interpolate(message?.value(count: values["count"]) ?? key, values)
    }

    static func interpolate(_ template: String, _ values: [String: String]) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\{([A-Za-z][\w]*)\}"#)
        var result = template
        for match in pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let nameRange = Range(match.range(at: 1), in: template),
                  let replacement = values[String(template[nameRange])],
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

func L(_ key: String, _ values: [String: String] = [:]) -> String {
    Localization.text(key, values)
}
