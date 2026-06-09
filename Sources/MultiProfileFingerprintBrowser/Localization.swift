import Foundation

enum Localization {
    static var isChinese: Bool {
        let override = ProcessInfo.processInfo.environment["MPFB_UI_LANGUAGE"]?.lowercased()
        if let override {
            return override.hasPrefix("zh")
        }
        return true
    }

    static func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
