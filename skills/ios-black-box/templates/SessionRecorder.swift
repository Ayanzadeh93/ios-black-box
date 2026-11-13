//
//  SessionRecorder.swift — Black Box (ios-black-box skill)
//
//  Debug-only flight recorder: the app's screen plus its own audio, saved to
//  Documents/recordings/session-<time>.mp4 for `session.sh pull`, plus a
//  session-<time>.json sidecar: approximate start-completion and stop-request
//  uptimes. Log your events with ProcessInfo.processInfo.systemUptime and
//  `session.sh pull` maps each one onto the video timeline (timeline.csv).
//
//  Off unless launched with `-recordSession YES`. iOS asks before every
//  recording; the microphone is never recorded. Stops when the app leaves
//  the foreground or after `-recordSeconds` (default 180).
//
//  Wire it up in application(_:didFinishLaunchingWithOptions:):
//      #if DEBUG
//      SessionRecorder.shared.startIfRequested()
//      #endif
//
//  After a segment has finished saving, a Debug control on the main actor may
//  call SessionRecorder.shared.startNextSegment() to request a new segment
//  without relaunching the app. Each request may show ReplayKit consent again.
//  A true return means the start request was accepted, not that capture started.
//

#if DEBUG
import Foundation
import OSLog
import ReplayKit
import UIKit

@MainActor
final class SessionRecorder {
    static let shared = SessionRecorder()

    private let recorder = RPScreenRecorder.shared()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "BlackBox")
    private var observers: [NSObjectProtocol] = []
    private var stopTask: Task<Void, Never>?
    private var startedOnce = false
    private var starting = false
    private var stopping = false
    private var segmentID = UUID()
    private var pendingStopReason: String?
    private var startRequestUptime: TimeInterval?
    /// `systemUptime` observed in ReplayKit's start completion callback.
    /// This is an approximate anchor, not the first media sample timestamp.
    private(set) var recordingStartUptime: TimeInterval?
    private var recordingStartWall: Date?

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings", isDirectory: true)
    }

    /// Starts on first activation, when ReplayKit can show its consent prompt.
    func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: "recordSession"), observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startOnce() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: "left foreground") }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: "entered background") }
        })
        if UIApplication.shared.applicationState == .active { startOnce() }
    }

    private func startOnce() {
        guard !startedOnce else { return }
        startNextSegment()
    }

    /// Explicitly request another foreground segment without relaunching the app.
    /// Call from a Debug UI after startIfRequested() has installed lifecycle hooks.
    /// Returns false while starting, recording or saving, or when capture is disabled
    /// or unavailable. A true result still requires successful ReplayKit consent.
    @discardableResult
    func startNextSegment() -> Bool {
        guard UserDefaults.standard.bool(forKey: "recordSession"), !observers.isEmpty,
              UIApplication.shared.applicationState == .active,
              recorder.isAvailable, !recorder.isRecording, !starting, !stopping else { return false }
        startedOnce = true  // Never automatically rearm on a later activation.
        starting = true
        stopTask?.cancel()
        stopTask = nil
        recordingStartUptime = nil
        recordingStartWall = nil
        pendingStopReason = nil
        let currentSegment = UUID()
        segmentID = currentSegment
        recorder.isMicrophoneEnabled = false
        startRequestUptime = ProcessInfo.processInfo.systemUptime
        recorder.startRecording { [weak self] error in
            let callbackUptime = ProcessInfo.processInfo.systemUptime
            let callbackWall = Date()
            Task { @MainActor in
                guard let self, self.segmentID == currentSegment else { return }
                self.starting = false
                if let error {
                    self.pendingStopReason = nil
                    self.log.error("start failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                self.recordingStartUptime = callbackUptime
                self.recordingStartWall = callbackWall
                // A successful callback can arrive after a background transition.
                // Temporary .inactive is expected while ReplayKit dismisses consent.
                if UIApplication.shared.applicationState == .background {
                    self.pendingStopReason = self.pendingStopReason ?? "background during start"
                }
                if let reason = self.pendingStopReason {
                    self.pendingStopReason = nil
                    self.stop(reason: reason)
                    return
                }
                let stored = UserDefaults.standard.double(forKey: "recordSeconds")
                let seconds = stored.isFinite && stored > 0 ? min(stored, 3600) : 180
                self.log.info("recording (\(Int(seconds)) s max)")
                self.stopTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard let self, self.segmentID == currentSegment else { return }
                    self.stop(reason: "time limit")
                }
            }
        }
        return true
    }

    private func stop(reason: String) {
        guard !stopping else { return }
        // ReplayKit consent temporarily resigns activity. During startup, queue
        // only a real background transition, even before isRecording turns true.
        if starting {
            if UIApplication.shared.applicationState == .background { pendingStopReason = reason }
            return
        }
        guard recorder.isRecording else { return }
        stopping = true
        let currentSegment = segmentID
        stopTask?.cancel()
        stopTask = nil
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            + "-" + String(UUID().uuidString.prefix(8))
        let url = Self.directory.appendingPathComponent("session-\(stamp).mp4")
        let stopUptime = ProcessInfo.processInfo.systemUptime
        let clock: [String: Any] = [
            "schemaVersion": 2,
            "alignment": "approximate",
            "startAnchor": "replaykit-start-completion",
            "stopAnchor": "stop-request",
            "startRequestUptime": startRequestUptime ?? recordingStartUptime ?? stopUptime,
            "alignmentNote": "ReplayKit first-sample timestamps are unavailable through startRecording; calibrate using a visible or audible marker.",
            "video": url.lastPathComponent,
            "clock": "systemUptime",
            "startUptime": recordingStartUptime ?? stopUptime,
            "stopUptime": stopUptime,
            "startWall": ISO8601DateFormatter().string(from: recordingStartWall ?? Date()),
            "reason": reason,
        ]
        let clockData: Data
        do {
            clockData = try JSONSerialization.data(withJSONObject: clock, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        } catch {
            log.error("cannot prepare recording export: \(error.localizedDescription, privacy: .public)")
            recorder.stopRecording { [weak self, log] _, error in
                if let error { log.error("stop failed: \(error.localizedDescription, privacy: .public)") }
                Task { @MainActor in
                    guard let self, self.segmentID == currentSegment else { return }
                    self.stopping = false
                }
            }
            return
        }
        recorder.stopRecording(withOutput: url) { [weak self, log] error in
            if let error {
                log.error("save failed: \(error.localizedDescription, privacy: .public)")
            } else {
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                do {
                    try clockData.write(to: sidecar, options: .atomic)
                    log.info("saved (\(reason, privacy: .public))")
                } catch {
                    log.error("video saved but clock sidecar failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Release the save guard only after this segment's sidecar work ends.
            Task { @MainActor in
                guard let self, self.segmentID == currentSegment else { return }
                self.stopping = false
            }
        }
    }
}
#endif
