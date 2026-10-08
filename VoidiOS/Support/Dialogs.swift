import UIKit

/// Alerts shown over whatever is on screen (the browser, or a sheet above it).
@MainActor
enum Dialogs {
    /// The view controller an alert can be presented from, or nil when there is none (the app is
    /// in the background, or a system sheet such as Quick Look is in the way).
    static var presenter: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top is UIAlertController ? nil : top
    }

    /// nil when the alert couldn't be shown.
    static func confirm(title: String, message: String, confirm: String = "OK", cancel: String? = String(localized: "Annuler"),
                        destructive: Bool = false) async -> Bool? {
        guard let presenter else { return nil }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            if let cancel {
                alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in continuation.resume(returning: false) })
            }
            let action = UIAlertAction(title: confirm, style: destructive ? .destructive : .default) { _ in continuation.resume(returning: true) }
            alert.addAction(action)
            alert.preferredAction = action
            presenter.present(alert, animated: true)
        }
    }

    struct Field {
        var placeholder: String
        var text = ""
        var secure = false
    }

    /// The fields' texts, or nil when cancelled or when the alert couldn't be shown.
    static func prompt(title: String, message: String, fields: [Field], confirm: String = "OK") async -> [String]? {
        guard let presenter else { return nil }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for field in fields {
                alert.addTextField { textField in
                    textField.placeholder = field.placeholder
                    textField.text = field.text
                    textField.isSecureTextEntry = field.secure
                    textField.autocapitalizationType = .none
                    textField.autocorrectionType = .no
                }
            }
            alert.addAction(UIAlertAction(title: String(localized: "Annuler"), style: .cancel) { _ in continuation.resume(returning: nil) })
            let action = UIAlertAction(title: confirm, style: .default) { [weak alert] _ in
                continuation.resume(returning: (alert?.textFields ?? []).map { $0.text ?? "" })
            }
            alert.addAction(action)
            alert.preferredAction = action
            presenter.present(alert, animated: true)
        }
    }
}
