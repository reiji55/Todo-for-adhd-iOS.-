import Foundation

/// The reverse-domain name everything of this edition is named under (the app ID, its iCloud container, its
/// widgets). The full edition keeps the name it always had, so its data stays where it was; the App Store edition
/// has its own. It comes from the build (HORME_ID_BASE, written into Info.plist as HormeIDBase).
enum HormeID {
    #if HORME_STORE
    static let fallback = "com.hormeapp.ios"
    #else
    static let fallback = "io.github.reiji55.threedays"
    #endif
    static let base: String = (Bundle.main.object(forInfoDictionaryKey: "HormeIDBase") as? String)
        .flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 } ?? fallback
}
