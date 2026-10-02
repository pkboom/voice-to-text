import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Observation
import Speech

enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied

    var isGranted: Bool { self == .granted }
}

/// The TCC grants the app needs: Microphone, Accessibility (posting Cmd+V), Input Monitoring
/// (the listen-only hotkey tap) and, defensively, Speech Recognition.
///
/// Statuses are re-read by `refresh()`, which `startMonitoring()` calls every 2 s (the menu has no
/// reliable "will open" hook), so a grant made in System Settings shows up without a relaunch.
///
/// The system calls the request completion handlers on arbitrary queues, so the requests are
/// wrapped in `nonisolated` continuation helpers: a MainActor-isolated closure invoked off the
/// main thread would trap under Swift 6.
@Observable
final class PermissionsManager {
    enum Grant: CaseIterable, Identifiable {
        case microphone
        case accessibility
        case inputMonitoring
        case speech

        var id: Self { self }

        var displayName: String {
            switch self {
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .inputMonitoring: "Input Monitoring"
            case .speech: "Speech Recognition"
            }
        }

        /// System Settings › Privacy & Security pane for this grant.
        var settingsURL: URL {
            let anchor = switch self {
            case .microphone: "Privacy_Microphone"
            case .accessibility: "Privacy_Accessibility"
            case .inputMonitoring: "Privacy_ListenEvent"
            case .speech: "Privacy_SpeechRecognition"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    static let refreshInterval: Duration = .seconds(2)

    private(set) var microphone: PermissionStatus = .notDetermined
    private(set) var speech: PermissionStatus = .notDetermined
    private(set) var accessibility: PermissionStatus = .notDetermined
    private(set) var inputMonitoring: PermissionStatus = .notDetermined

    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    init() {
        refresh()
    }

    func status(of grant: Grant) -> PermissionStatus {
        switch grant {
        case .microphone: microphone
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        case .speech: speech
        }
    }

    func refresh() {
        // Assign only on change so observers are not invalidated every tick.
        let newMicrophone = Self.microphoneStatus()
        let newSpeech = Self.speechStatus()
        let newAccessibility: PermissionStatus = AXIsProcessTrusted() ? .granted : .denied
        let newInputMonitoring: PermissionStatus = CGPreflightListenEventAccess() ? .granted : .denied
        if microphone != newMicrophone { microphone = newMicrophone }
        if speech != newSpeech { speech = newSpeech }
        if accessibility != newAccessibility { accessibility = newAccessibility }
        if inputMonitoring != newInputMonitoring { inputMonitoring = newInputMonitoring }
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                self?.refresh()
            }
        }
    }

    /// First launch: prompts for the grants that have a system prompt (Mic, then Speech
    /// defensively, then Input Monitoring). Accessibility is requested from the menu.
    func requestLaunchPermissions() async {
        if microphone == .notDetermined {
            await requestMicrophone()
        }
        if speech == .notDetermined {
            await requestSpeech()
        }
        if !inputMonitoring.isGranted {
            _ = CGRequestListenEventAccess()
            refresh()
        }
    }

    /// The menu's "Open Settings…" action. Requests first where that registers the app in the
    /// pane (or shows the one-time prompt), then opens the pane.
    func openSettings(for grant: Grant) async {
        switch grant {
        case .microphone where microphone == .notDetermined:
            await requestMicrophone()
            return
        case .speech where speech == .notDetermined:
            await requestSpeech()
            return
        case .accessibility:
            // The key is the value of `kAXTrustedCheckOptionPrompt`.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        default:
            break
        }
        NSWorkspace.shared.open(grant.settingsURL)
        refresh()
    }

    func requestMicrophone() async {
        _ = await Self.requestMicrophoneAccess()
        refresh()
    }

    func requestSpeech() async {
        _ = await Self.requestSpeechAuthorization()
        refresh()
    }

    nonisolated static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    nonisolated static func speechStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    nonisolated static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
