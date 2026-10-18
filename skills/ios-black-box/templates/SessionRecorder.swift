//
//  SessionRecorder.swift — Black Box (ios-black-box skill)
//
//  Debug-only flight recorder: the app's screen plus its own audio, saved to
//  Documents/recordings/session-<time>.mp4 for `session.sh pull`, plus a
//  session-<time>.json clock sidecar: the system uptime when recording started
//  and stopped. Log your events with ProcessInfo.processInfo.systemUptime and
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
    /// `systemUptime` when the first frame was being captured (nil until then).
    /// Log it in your own trace if you want an in-log anchor too.
    private(set) var recordingStartUptime: TimeInterval?
    private var recordingStartWall: Date?

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings", isDirectory: true)
    }

    /// Starts on first activation, when ReplayKit can show its consent prompt.
    func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: "recordSession") else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startOnce() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: "left foreground") }
        })
    }

    private func startOnce() {
        guard !startedOnce, recorder.isAvailable else { return }
        startedOnce = true
        recorder.isMicrophoneEnabled = false
        recorder.startRecording { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log.error("start failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                self.recordingStartUptime = ProcessInfo.processInfo.systemUptime
                self.recordingStartWall = Date()
                let stored = UserDefaults.standard.double(forKey: "recordSeconds")
                let seconds = stored > 0 ? stored : 180
                self.log.info("recording (\(Int(seconds)) s max)")
                self.stopTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    self?.stop(reason: "time limit")
                }
            }
        }
    }

    private func stop(reason: String) {
        guard recorder.isRecording else { return }
        stopTask?.cancel()
        stopTask = nil
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = Self.directory.appendingPathComponent("session-\(stamp).mp4")
        let stopUptime = ProcessInfo.processInfo.systemUptime
        let clock: [String: Any] = [
            "video": url.lastPathComponent,
            "clock": "systemUptime",
            "startUptime": recordingStartUptime ?? stopUptime,
            "stopUptime": stopUptime,
            "startWall": ISO8601DateFormatter().string(from: recordingStartWall ?? Date()),
            "reason": reason,
        ]
        let clockData = try? JSONSerialization.data(withJSONObject: clock, options: [.prettyPrinted, .sortedKeys])
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        } catch {
            log.error("no recordings folder: \(error.localizedDescription, privacy: .public)")
            return
        }
        recorder.stopRecording(withOutput: url) { [log] error in
            if let error {
                log.error("save failed: \(error.localizedDescription, privacy: .public)")
            } else {
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                try? clockData?.write(to: sidecar)
                log.info("saved (\(reason, privacy: .public))")
            }
        }
    }
}
#endif
