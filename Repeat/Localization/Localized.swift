import Foundation

/// Resolving a *language* rather than just a locale (#38).
///
/// `String(localized:locale:)` does not do what its signature suggests. The
/// `locale` argument selects the **plural rule** and the number/date formatting;
/// the **strings** still come from whatever language the bundle resolved at
/// launch. Ask for `locale: uk` from an English-resolved bundle and you get
/// English text inflected by Ukrainian grammar — literally "21 card is waiting to
/// be reviewed", singular, because Ukrainian puts 21 in the `one` category.
///
/// Production never needs this: the bundle resolves the reader's language and
/// `Locale.current` agrees with it. It exists so a test can pin a language and
/// assert real copy, which is the only way the plural rules in
/// `Localizable.xcstrings` can be checked at all.
enum Localized {
    /// The `.lproj` bundle for a locale's language, or `.main` when the app does
    /// not ship that language — which is also the right answer, since that is
    /// exactly what the reader would get.
    static func bundle(for locale: Locale) -> Bundle {
        guard let code = locale.language.languageCode?.identifier,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    /// One call so the bundle and the locale can never disagree.
    static func string(_ key: String.LocalizationValue, locale: Locale = .current) -> String {
        String(localized: key, bundle: bundle(for: locale), locale: locale)
    }
}
