//
//  SensorTape.swift — ios-sensor-tape skill
//
//  Debug-only recorder that turns a real app session into a replayable tape:
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
//  time limit, counted from recorder activation, even without camera frames.
//  Motion needs NSMotionUsageDescription in Info.plist.
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

    private enum CaptureError: LocalizedError {
        case frameDimensions, jpegEncoding, depthFormat
        var errorDescription: String? {
            switch self {
            case .frameDimensions: return "camera frame has invalid or unsupported dimensions"
            case .jpegEncoding: return "camera frame could not be encoded as JPEG"
            case .depthFormat: return "depth buffer must provide a readable DepthFloat32 map"
            }
        }
    }

    private let queue = DispatchQueue(label: "sensor-tape.writer", qos: .utility)
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "SensorTape")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let motion = CMMotionManager()
    private let lock = NSLock()

    // Guarded by `lock` (read on the caller's thread, written on `queue`).
    private var _recording = false
    private var _encoding = false
    private var _generation: UInt64 = 0
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
    private var activeGeneration: UInt64 = 0
    // Registered once on the main actor; retained for the singleton's lifetime.
    private var lifecycleObserver: NSObjectProtocol?

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
        if lifecycleObserver == nil {
            lifecycleObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.stop(reason: "left foreground") }
        }
    }

    func start(fps: Double, seconds: TimeInterval, scale: Double = 0.5) {
        guard fps.isFinite, fps > 0, fps <= 240, (1 / fps).isFinite,
              seconds.isFinite, seconds > 0, seconds <= 86_400,
              scale.isFinite, scale > 0, scale <= 1 else {
            log.error("invalid tape settings: require 0 < fps <= 240, 0 < seconds <= 86400, 0 < scale <= 1")
            return
        }
        queue.async { [self] in
            guard dir == nil else { return }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = Self.directory.appendingPathComponent("tape-\(stamp)-\(UUID().uuidString)", isDirectory: true)
            do {
                for sub in ["frames", "depth"] {
                    try FileManager.default.createDirectory(at: url.appendingPathComponent(sub),
                                                            withIntermediateDirectories: true)
                }
                let indexURL = url.appendingPathComponent("index.jsonl")
                guard FileManager.default.createFile(atPath: indexURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                index = try FileHandle(forWritingTo: indexURL)
            } catch {
                log.error("cannot create tape: \(error.localizedDescription, privacy: .public)")
                return
            }
            dir = url
            frameCount = 0
            depthCount = 0
            startUptime = ProcessInfo.processInfo.systemUptime
            do {
                try writeMeta(["fps": fps, "maxSeconds": seconds, "scale": scale,
                               "durationOrigin": "recorderStart", "state": "recording"])
            } catch {
                failOnQueue(error)
                return
            }
            lock.withLock {
                _generation &+= 1
                activeGeneration = _generation
                self.scale = CGFloat(scale)
                minInterval = 1 / fps
                _lastFrameT = -.infinity
                _encoding = false
                _recording = true
            }
            let generation = activeGeneration
            startMotion(generation: generation)
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                self.stopOnQueue(reason: "time limit")
            }
            stopTimer = timer
            queue.asyncAfter(deadline: .now() + seconds, execute: timer)
            log.info("recording tape at \(fps) fps → \(url.lastPathComponent, privacy: .public)")
        }
    }

    func stop(reason: String = "stopped") {
        lock.withLock { _recording = false }
        queue.async { [self] in stopOnQueue(reason: reason) }
    }

    // MARK: Samples

    /// Offer a camera frame (and optional Float32 depth map). Cheap to call on
    /// every frame: it keeps at most `tapeFPS` per second and drops a frame
    /// rather than hold a camera buffer while the previous one is encoding.
    func offer(_ pixelBuffer: CVPixelBuffer, depth: CVPixelBuffer? = nil, at t: TimeInterval) {
        let accepted: (UInt64, CGFloat)? = lock.withLock {
            guard t.isFinite, t >= 0, _recording, !_encoding,
                  t - _lastFrameT >= minInterval else { return nil }
            _encoding = true
            _lastFrameT = t
            return (_generation, scale)
        }
        guard let (generation, s) = accepted else { return }
        let full = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = s < 1 ? full.transformed(by: CGAffineTransform(scaleX: s, y: s)) : full
        // Crop fractional edge pixels so the indexed dimensions match the JPEG.
        let image = scaled.cropped(to: CGRect(origin: scaled.extent.origin,
            size: CGSize(width: floor(scaled.extent.width), height: floor(scaled.extent.height))))
        let hadDepth = depth != nil
        let depthData = depth.flatMap(Self.float32Data)
        queue.async { [self] in
            defer { lock.withLock { if _generation == generation { _encoding = false } } }
            guard let url = dir, activeGeneration == generation else { return }
            let name = String(format: "%06d", frameCount + 1)
            var row: [String: Any] = ["t": t, "kind": "frame", "file": "frames/\(name).jpg"]
            do {
                guard image.extent.width.isFinite, image.extent.height.isFinite,
                      image.extent.width >= 1, image.extent.height >= 1,
                      image.extent.width <= 16_384, image.extent.height <= 16_384,
                      image.extent.width * image.extent.height <= 67_108_864 else {
                    throw CaptureError.frameDimensions
                }
                row["w"] = Int(image.extent.width)
                row["h"] = Int(image.extent.height)
                guard let jpeg = ciContext.jpegRepresentation(
                    of: image, colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7]) else {
                    throw CaptureError.jpegEncoding
                }
                try jpeg.write(to: url.appendingPathComponent("frames/\(name).jpg"), options: .atomic)
                if hadDepth, depthData == nil { throw CaptureError.depthFormat }
                if let (data, w, h) = depthData {
                    let packed = try (data as NSData).compressed(using: .lzfse) as Data
                    try packed.write(to: url.appendingPathComponent("depth/\(name).f32.lzfse"), options: .atomic)
                    row["depth"] = "depth/\(name).f32.lzfse"
                    row["dw"] = w
                    row["dh"] = h
                }
                try append(row)
                if frameCount == 0 { try writeMeta(["firstFrameUptime": t]) }
                frameCount += 1
                if depthData != nil { depthCount += 1 }
            } catch {
                failOnQueue(error)
            }
        }
    }

    /// Log anything else on the same clock (detections, decisions, labels...).
    func event(_ name: String, _ fields: [String: Any] = [:], at t: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard t.isFinite, t >= 0, !name.isEmpty, JSONSerialization.isValidJSONObject(fields),
              let generation = lock.withLock({ _recording ? _generation : nil }) else { return }
        var row = fields
        row["t"] = t
        row["kind"] = "event"
        row["name"] = name
        let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        queue.async { [self] in
            guard let data, dir != nil, activeGeneration == generation else { return }
            do { try appendLine(data) } catch { failOnQueue(error) }
        }
    }

    // MARK: Internals

    private func startMotion(generation: UInt64) {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        // CMDeviceMotion.timestamp is seconds since boot: the same clock as systemUptime.
        motion.startDeviceMotionUpdates(to: opQueue) { [weak self] m, _ in
            guard let self, let m, m.timestamp.isFinite,
                  self.lock.withLock({ self._recording && self._generation == generation }) else { return }
            let q = m.attitude.quaternion
            let row: [String: Any] = [
                "t": m.timestamp, "kind": "imu",
                "q": [q.w, q.x, q.y, q.z],
                "rot": [m.rotationRate.x, m.rotationRate.y, m.rotationRate.z],
                "acc": [m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z],
                "grav": [m.gravity.x, m.gravity.y, m.gravity.z],
            ]
            let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            self.queue.async {
                guard self.dir != nil, self.activeGeneration == generation else { return }
                do { try self.appendLine(line) } catch { self.failOnQueue(error) }
            }
        }
    }

    private func append(_ row: [String: Any]) throws {
        try appendLine(JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    }

    private func appendLine(_ data: Data?) throws {
        guard let index, var data else { throw CocoaError(.fileWriteUnknown) }
        data.append(0x0A)
        try index.write(contentsOf: data)
    }

    private func stopOnQueue(reason: String, failed: Bool = false) {
        guard let url = dir else { return }
        lock.withLock { _recording = false }
        motion.stopDeviceMotionUpdates()
        stopTimer?.cancel()
        stopTimer = nil
        let stopped = ProcessInfo.processInfo.systemUptime
        do {
            try index?.synchronize()
            try index?.close()
            try writeMeta(["stopUptime": stopped, "durationSeconds": stopped - startUptime,
                           "frames": frameCount, "depthMaps": depthCount, "reason": reason,
                           "state": failed ? "failed" : "complete"])
        } catch {
            log.error("cannot finalize tape: \(error.localizedDescription, privacy: .public)")
        }
        index = nil
        dir = nil
        activeGeneration = 0
        log.info("tape stopped (\(reason, privacy: .public)): \(url.lastPathComponent, privacy: .public)")
    }

    private func failOnQueue(_ error: Error) {
        log.error("tape write failed: \(error.localizedDescription, privacy: .public)")
        stopOnQueue(reason: "write error: \(error.localizedDescription)", failed: true)
    }

    private func writeMeta(_ extra: [String: Any]) throws {
        guard let url = dir else { throw CocoaError(.fileWriteUnknown) }
        let metaURL = url.appendingPathComponent("meta.json")
        var meta: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: metaURL.path) {
            let data = try Data(contentsOf: metaURL)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            meta = existing
        }
        if meta.isEmpty {
            meta = ["schema": 1, "clock": "systemUptime", "startUptime": startUptime,
                    "startWall": ISO8601DateFormatter().string(from: Date()),
                    "device": Self.modelIdentifier,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString]
        }
        meta.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metaURL, options: .atomic)
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
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0, w <= 16_384, h <= 16_384, w * h <= 16_777_216 else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: w * h * 4)
        for y in 0..<h {
            data.append(base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self), count: w * 4)
        }
        return (data, w, h)
    }
}
#endif
