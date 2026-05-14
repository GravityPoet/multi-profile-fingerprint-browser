import Foundation

enum Localization {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    static func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
