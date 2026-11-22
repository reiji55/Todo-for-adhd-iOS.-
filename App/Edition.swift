import Foundation

/// Which Horme this is. The full edition (sent to TestFlight for the developer) has Claude連携 and file
/// backups; the App Store edition is built with HORME_STORE and leaves them out of the app altogether.
enum Edition {
    #if HORME_STORE
    static let full = false
    #else
    static let full = true
    #endif
}
