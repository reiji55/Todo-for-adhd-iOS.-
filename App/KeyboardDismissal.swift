import UIKit

/// A tap anywhere outside the text being typed puts the keyboard away, on every screen and sheet. The tap
/// still reaches what was tapped (a button works as usual); a tap on a text field or text area is left alone.
@MainActor
final class KeyboardDismissal: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissal()
    private var installed: Set<ObjectIdentifier> = []
    private var keyboardShown = false
    private var observing = false

    func install() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardShown = true
                self?.attachToWindows()
            }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardShown = false }
        }
    }

    /// Windows come and go (a sheet can bring its own), so each is given the recognizer when the keyboard shows.
    private func attachToWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windows = (scene as? UIWindowScene)?.windows else { continue }
            for window in windows where !installed.contains(ObjectIdentifier(window)) {
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                tap.cancelsTouchesInView = false
                tap.delaysTouchesBegan = false
                tap.delaysTouchesEnded = false
                tap.delegate = self
                window.addGestureRecognizer(tap)
                installed.insert(ObjectIdentifier(window))
            }
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard keyboardShown else { return }
        recognizer.view?.endEditing(true)
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            guard keyboardShown else { return false }
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UISearchBar { return false }
                view = current.superview
            }
            return true
        }
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
