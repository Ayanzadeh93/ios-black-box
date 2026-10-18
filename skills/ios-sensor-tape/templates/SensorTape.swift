//
//  SensorTape.swift — ios-sensor-tape skill
//
//  Debug-only recorder that turns a real walk into a replayable tape:
//  camera frames (JPEG, subsampled), depth maps (Float32, LZFSE), device
//  motion (50 Hz) and your own events, all on the systemUptime clock.
//
//  Documents/tapes/tape-<time>/
//    meta.json     clock, device, fps, start/stop uptime
//    index.jsonl   one line per sample, in arrival order
//    frames/       000001.jpg ...
//    depth/        000001.f32.lzfse ...
//
//  Off unless launched with `-recordTape YES` (optional `-tapeFPS 5`,
//  `-tapeSeconds 60`, `-tapeScale 0.5` for frame size; 1 keeps full resolution). Stops when the app leaves the foreground or at the
//  time limit, counted from the first camera frame (not from launch). Motion needs NSMotionUsageDescription in Info.plist.
//
//  Wire it up:
//      // at launch
//      #if DEBUG
//      SensorTape.shared.startIfRequested()
//      #endif
//      // wherever frames arrive (e.g. ARSessionDelegate didUpdate)
//      #if DEBUG
//      SensorTape.shared.offer(frame.capturedImage, depth: frame.smoothedSceneDepth?.depthMap,
//                              at: frame.timestamp)
//      #endif
//

#if DEBUG
import CoreImage
import CoreMotion
import CoreVideo
import Foundation
import OSLog
import UIKit

nonisolated final class SensorTape: @unchecked Sendable {
    static let shared = SensorTape()

    private let queue = DispatchQueue(label: "sensor-tape.writer", qos: .utility)
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "SensorTape")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let motion = CMMotionManager()
    private let lock = NSLock()

    // Guarded by `lock` (read on the caller's thread, written on `queue`).
    private var _recording = false
    private var _encoding = false
    private var _lastFrameT: TimeInterval = -.infinity
    private var minInterval: TimeInterval = 0.2
    private var scale: CGFloat = 0.5

    // Only touched on `queue`.
    private var dir: URL?
    private var index: FileHandle?
    private var frameCount = 0
    private var depthCount = 0
    private var startUptime: TimeInterval = 0
    private var stopTimer: DispatchWorkItem?
    private var maxSeconds: TimeInterval = 60

    var isRecording: Bool { lock.withLock { _recording } }

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tapes", isDirectory: true)
    }

    // MARK: Control

    /// Starts when launched with `-recordTape YES`.
    @MainActor func startIfRequested() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "recordTape") else { return }
        let fps = defaults.double(forKey: "tapeFPS")
        let seconds = defaults.double(forKey: "tapeSeconds")
        let scale = defaults.double(forKey: "tapeScale")
        start(fps: fps > 0 ? fps : 5, seconds: seconds > 0 ? seconds : 60, scale: scale > 0 ? min(scale, 1) : 0.5)
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.stop(reason: "left foreground")
        }
    }

    func start(fps: Double, seconds: TimeInterval, scale: Double = 0.5) {
        queue.async { [self] in
            guard dir == nil else { return }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = Self.directory.appendingPathComponent("tape-\(stamp)", isDirectory: true)
            do {
                for sub in ["frames", "depth"] {
                    try FileManager.default.createDirectory(at: url.appendingPathComponent(sub),
                                                            withIntermediateDirectories: true)
                }
                let indexURL = url.appendingPathComponent("index.jsonl")
                FileManager.default.createFile(atPath: indexURL.path, contents: nil)
                index = try FileHandle(forWritingTo: indexURL)
            } catch {
                log.error("cannot create tape: \(error.localizedDescription, privacy: .public)")
                return
            }
            dir = url
            frameCount = 0
            depthCount = 0
            startUptime = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                self.scale = CGFloat(scale)
                minInterval = 1 / fps
                _lastFrameT = -.infinity
                _recording = true
            }
            maxSeconds = seconds
            writeMeta(["fps": fps, "maxSeconds": seconds, "scale": scale])
            log.info("recording tape at \(fps) fps → \(url.lastPathComponent, privacy: .public)")
        }
        startMotion()
    }

    func stop(reason: String = "stopped") {
        lock.withLock { _recording = false }
        motion.stopDeviceMotionUpdates()
        queue.async { [self] in
            guard let url = dir else { return }
            stopTimer?.cancel()
            stopTimer = nil
            writeMeta(["stopUptime": ProcessInfo.processInfo.systemUptime, "frames": frameCount,
                       "depthMaps": depthCount, "reason": reason])
            try? index?.close()
            index = nil
            dir = nil
            log.info("tape saved (\(reason, privacy: .public)): \(url.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: Samples

    /// Offer a camera frame (and optional Float32 depth map). Cheap to call on
    /// every frame: it keeps at most `tapeFPS` per second and drops a frame
    /// rather than hold a camera buffer while the previous one is encoding.
    func offer(_ pixelBuffer: CVPixelBuffer, depth: CVPixelBuffer? = nil, at t: TimeInterval) {
        let accept: Bool = lock.withLock {
            guard _recording, !_encoding, t - _lastFrameT >= minInterval * 0.9 else { return false }
            _encoding = true
            _lastFrameT = t
            return true
        }
        guard accept else { return }
        let s = lock.withLock { scale }
        let full = CIImage(cvPixelBuffer: pixelBuffer)
        let image = s < 1 ? full.transformed(by: CGAffineTransform(scaleX: s, y: s)) : full
        let depthData = depth.flatMap(Self.float32Data)
        queue.async { [self] in
            defer { lock.withLock { _encoding = false } }
            guard let url = dir else { return }
            if frameCount == 0 {
                // The time limit starts with the camera, so reaching the
                // camera screen never eats into the recording.
                let timer = DispatchWorkItem { [weak self] in self?.stop(reason: "time limit") }
                stopTimer = timer
                queue.asyncAfter(deadline: .now() + maxSeconds, execute: timer)
                writeMeta(["firstFrameUptime": t])
            }
            frameCount += 1
            let name = String(format: "%06d", frameCount)
            var row: [String: Any] = ["t": t, "kind": "frame", "file": "frames/\(name).jpg",
                                      "w": Int(image.extent.width), "h": Int(image.extent.height)]
            if let jpeg = ciContext.jpegRepresentation(
                of: image, colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7]) {
                try? jpeg.write(to: url.appendingPathComponent("frames/\(name).jpg"))
            }
            if let (data, w, h) = depthData,
               let packed = try? (data as NSData).compressed(using: .lzfse) as Data {
                depthCount += 1
                try? packed.write(to: url.appendingPathComponent("depth/\(name).f32.lzfse"))
                row["depth"] = "depth/\(name).f32.lzfse"
                row["dw"] = w
                row["dh"] = h
            }
            append(row)
        }
    }

    /// Log anything else on the same clock (detections, decisions, labels...).
    func event(_ name: String, _ fields: [String: Any] = [:], at t: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isRecording, JSONSerialization.isValidJSONObject(fields) else { return }
        var row = fields
        row["t"] = t
        row["kind"] = "event"
        row["name"] = name
        let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        queue.async { [self] in
            guard let data else { return }
            index?.write(data)
            index?.write(Data([0x0A]))
        }
    }

    // MARK: Internals

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        // CMDeviceMotion.timestamp is seconds since boot: the same clock as systemUptime.
        motion.startDeviceMotionUpdates(to: opQueue) { [weak self] m, _ in
            guard let self, let m, self.isRecording else { return }
            let q = m.attitude.quaternion
            let row: [String: Any] = [
                "t": m.timestamp, "kind": "imu",
                "q": [q.w, q.x, q.y, q.z],
                "rot": [m.rotationRate.x, m.rotationRate.y, m.rotationRate.z],
                "acc": [m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z],
                "grav": [m.gravity.x, m.gravity.y, m.gravity.z],
            ]
            let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            self.queue.async { self.appendLine(line) }
        }
    }

    private func append(_ row: [String: Any]) {
        appendLine(try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    }

    private func appendLine(_ data: Data?) {
        guard let index, let data else { return }
        index.write(data)
        index.write(Data([0x0A]))
    }

    private func writeMeta(_ extra: [String: Any]) {
        guard let url = dir else { return }
        let metaURL = url.appendingPathComponent("meta.json")
        var meta = (try? Data(contentsOf: metaURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if meta.isEmpty {
            meta = ["schema": 1, "clock": "systemUptime", "startUptime": startUptime,
                    "startWall": ISO8601DateFormatter().string(from: Date()),
                    "device": Self.modelIdentifier,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString]
        }
        meta.merge(extra) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: metaURL)
        }
    }

    /// e.g. "iPhone17,1": which phone recorded the tape.
    private static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Copies a Float32 depth map (e.g. ARFrame.smoothedSceneDepth.depthMap) out
    /// of its buffer immediately, so ARKit gets the buffer back.
    private static func float32Data(_ buffer: CVPixelBuffer) -> (Data, Int, Int)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: w * h * 4)
        for y in 0..<h {
            data.append(base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self), count: w * 4)
        }
        return (data, w, h)
    }
}
#endif
