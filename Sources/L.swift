import Foundation

/// Localized string lookup. Keys are the English text; translations live in
/// `en.lproj` / `zh-Hans.lproj` `Localizable.strings`.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string, e.g. `LF("%d ms", 120)`.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
