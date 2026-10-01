import Foundation

/// Simple stdout logger for debug output.
/// All messages are prefixed with `[iCHM]` for easy identification.
enum Log {
    static func info(_ message: String) {
        print("[\(AppConstants.appShortName)] \(message)")
    }
}
