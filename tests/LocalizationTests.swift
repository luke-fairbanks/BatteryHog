import Foundation

@main
enum LocalizationTests {
    static func main() {
        let cases: [([String], String)] = [
            (["zh-Hans-CN", "en"], "zh-Hans"), (["zh_CN"], "zh-Hans"),
            (["zh-SG"], "zh-Hans"), (["en-GB", "zh-Hans"], "en"),
            (["fr", "zh-Hans"], "zh-Hans"), (["zh-Hant", "en"], "en"),
            (["zh-TW"], "en"), (["de"], "en"), ([], "en")
        ]
        for (preferences, expected) in cases {
            precondition(Localization.language(for: preferences) == expected)
        }
        let result = Localization.interpolate("Quit {name} · {count}", ["name": "猫🐈{count}", "count": "2"])
        precondition(result == "Quit 猫🐈{count} · 2")
        precondition(L("Unknown future message") == "Unknown future message")
        if Localization.currentLanguage == "zh-Hans" {
            precondition(L("Open Workloads") == "查看工作负载")
            precondition(L("Quit {name}", ["name": "猫🐈"]) == "退出 猫🐈")
        } else {
            precondition(L("{count} projects", ["count": "1"]) == "1 project")
            precondition(L("{count} projects", ["count": "2"]) == "2 projects")
        }
        print("Native localization tests passed: \(Localization.currentLanguage)")
    }
}
