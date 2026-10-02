import CoreGraphics
import Foundation
import Observation
import os
import VoiceToTextCore

/// Global hold-to-talk on **Right Option** via a listen-only `CGEventTap` (Decision B1).
///
/// - Right Option is keycode 61 **plus** the device flag `NX_DEVICERALTKEYMASK` (0x40) in the raw
///   flags. The generic Option flag is never consulted, so Left Option (58 / 0x20) is ignored.
/// - Any `keyDown` while Right Option is held is reported as `.chord` (e.g. Right Option + e).
/// - Events are stamped from the injected `MonotonicClock` inside the callback, never from
///   `CGEvent.timestamp`.
/// - The tap runs on the main run loop; the C callback reaches this object through an `Unmanaged`
///   pointer and hops in with `MainActor.assumeIsolated`.
/// - A tap the system disabled (timeout / user input) is re-enabled. If `tapCreate` fails
///   (Input Monitoring not granted yet) the source reports `isTapActive == false` and retries every 2 s.
@Observable
final class CGEventTapHotkeySource: HotkeySource {
    static let rightOptionKeyCode: Int64 = 61
    /// `NX_DEVICERALTKEYMASK`.
    static let rightOptionDeviceMask: UInt64 = 0x40
    static let retryInterval: Duration = .seconds(2)

    private static let logger = Logger(subsystem: Latency.subsystem, category: "hotkey")

    /// `true` while the event tap exists and is enabled.
    private(set) var isTapActive = false

    @ObservationIgnored let events: AsyncStream<HotkeyEvent>
    @ObservationIgnored private let continuation: AsyncStream<HotkeyEvent>.Continuation
    @ObservationIgnored private let clock: any MonotonicClock
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var isHeld = false

    init(clock: any MonotonicClock = SystemMonotonicClock()) {
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream()
    }

    isolated deinit {
        stop()
        continuation.finish()
    }

    /// Creates the tap now, or keeps retrying every 2 s until it can be created. Never throws.
    func start() {
        guard tap == nil, retryTask == nil else { return }
        if installTap() { return }
        Self.logger.notice("event tap unavailable (Input Monitoring not granted?); retrying every 2 s")
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.retryInterval)
                guard let self, !Task.isCancelled else { return }
                if self.installTap() {
                    self.retryTask = nil
                    return
                }
            }
        }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isTapActive = false
        isHeld = false
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        isTapActive = true
        Self.logger.notice("event tap installed")
        return true
    }

    /// Called on the main thread from the tap callback. Only plain values cross in.
    fileprivate func handle(type: CGEventType, keyCode: Int64, rawFlags: UInt64) {
        let now = clock.now()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Self.logger.notice("event tap re-enabled after being disabled (type=\(type.rawValue, privacy: .public))")
            }
            // A release may have been missed while the tap was disabled.
            let current = CGEventSource.flagsState(.combinedSessionState).rawValue
            if isHeld, current & Self.rightOptionDeviceMask == 0 {
                isHeld = false
                continuation.yield(HotkeyEvent(.up, at: now))
            }
        case .flagsChanged:
            guard keyCode == Self.rightOptionKeyCode else { return }
            let isDown = rawFlags & Self.rightOptionDeviceMask != 0
            if isDown, !isHeld {
                isHeld = true
                continuation.yield(HotkeyEvent(.down, at: now))
            } else if !isDown, isHeld {
                isHeld = false
                continuation.yield(HotkeyEvent(.up, at: now))
            }
        case .keyDown:
            if isHeld {
                continuation.yield(HotkeyEvent(.chord, at: now))
            }
        default:
            break
        }
    }
}

/// The C callback. Runs on the main run loop (where the tap's source is installed); listen-only,
/// so the event is always passed through unchanged.
private nonisolated func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        // The source is MainActor-isolated (hence Sendable); the tap is torn down before it dies.
        let source = Unmanaged<CGEventTapHotkeySource>.fromOpaque(userInfo).takeUnretainedValue()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawFlags = event.flags.rawValue
        MainActor.assumeIsolated {
            source.handle(type: type, keyCode: keyCode, rawFlags: rawFlags)
        }
    }
    return Unmanaged.passUnretained(event)
}
