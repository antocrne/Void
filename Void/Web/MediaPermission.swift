import AVFoundation
import WebKit

/// Camera and microphone for a site (video calls: kMeet, Jitsi, Meet, Teams…). WebKit asks the
/// UI delegate; a page whose request gets no answer waits forever ("Configuring devices…").
/// Asked once per site and device until Void quits (private windows: until they close), and only
/// over the tab being shown. A refusal is kept a minute, so that a page asking in a loop doesn't
/// bring the question back at once.
@MainActor
enum MediaPermission {
    private static var allowed: Set<String> = []
    private static var refused: [String: Date] = [:]
    /// Questions on screen: a second request meanwhile (camera then micro) waits for the answer.
    private static var asking: [String: Task<Bool, Never>] = [:]

    /// "la caméra", "le micro", "la caméra et le micro".
    static func devices(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "la caméra"
        case .microphone: "le micro"
        default: "la caméra et le micro"
        }
    }

    /// `ask` shows the question ("Autoriser … ?") and returns the answer.
    static func decide(host: String, type: WKMediaCaptureType, in browser: BrowserModel,
                       ask: @escaping @MainActor () async -> Bool) async -> WKPermissionDecision {
        #if os(macOS) && DEBUG
        // Self-tests never open the camera, but the page gets its answer.
        if SelfTestRunner.isRequested { return .deny }
        #endif
        let key = (browser.isPrivate ? "\(ObjectIdentifier(browser).hashValue)|" : "") + "\(host)|\(type.rawValue)"
        if !allowed.contains(key) {
            if let date = refused[key], Date().timeIntervalSince(date) < 60 { return .deny }
            let task = asking[key] ?? Task { @MainActor in await ask() }
            asking[key] = task
            let answer = await task.value
            asking[key] = nil
            guard answer else {
                refused[key] = Date()
                return .deny
            }
            allowed.insert(key)
        }
        // The system's own permission for Void, asked the first time.
        for media in mediaTypes(type) where await !systemAllows(media) {
            browser.showToast("video.slash", systemRefusal(media))
            return .deny
        }
        return .grant
    }

    private static func mediaTypes(_ type: WKMediaCaptureType) -> [AVMediaType] {
        switch type {
        case .camera: [.video]
        case .microphone: [.audio]
        default: [.video, .audio]
        }
    }

    private static func systemAllows(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: media)
        default: false
        }
    }

    private static func systemRefusal(_ media: AVMediaType) -> String {
        let device = media == .video ? "la caméra" : "le micro"
        #if os(macOS)
        return "Void n'a pas accès à \(device) : Réglages Système → Confidentialité et sécurité"
        #else
        return "Void n'a pas accès à \(device) : Réglages → Void"
        #endif
    }
}
