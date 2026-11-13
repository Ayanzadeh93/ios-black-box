//
//  TapePlayer.swift — ios-sensor-tape skill
//
//  Validates and replays a finalized schema-1 tape in timestamp order.
//  JPEG/scaled input is repeatable; model output still depends on pipeline
//  state, preprocessing, hardware and numeric tolerances. Add to your test target.
//

import Compression
import CoreFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

struct TapePlayer {
    enum Kind: String { case frame, imu, event }

    struct Sample {
        let t: TimeInterval
        let kind: Kind
        let fields: [String: Any]
        var name: String? { fields["name"] as? String }
    }

    enum TapeError: Error, CustomStringConvertible {
        case missing(String), unreadable(String), invalid(String)
        var description: String {
            switch self {
            case .missing(let what): return "tape is missing \(what)"
            case .unreadable(let what): return "cannot read \(what)"
            case .invalid(let what): return "invalid tape: \(what)"
            }
        }
    }

    let url: URL
    let meta: [String: Any]
    /// Timestamp order, with original arrival order preserved for timestamp ties.
    let samples: [Sample]

    init(url: URL) throws {
        guard url.isFileURL else { throw TapeError.invalid("expected a local directory") }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        self.url = root
        let metaURL = try Self.assetURL("meta.json", root: root)
        let metaData = try Self.read(metaURL, limit: 1_048_576)
        guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              Self.number(meta["schema"]) == 1,
              meta["clock"] as? String == "systemUptime",
              let start = Self.number(meta["startUptime"]), start >= 0,
              let stop = Self.number(meta["stopUptime"]), stop >= start else {
            throw TapeError.invalid("require schema 1, systemUptime and finite ordered start/stop times")
        }
        if let state = meta["state"], state as? String != "complete" {
            throw TapeError.invalid("session state is \(state); expected complete")
        }
        self.meta = meta
        let indexURL = try Self.assetURL("index.jsonl", root: root)
        let data = try Self.read(indexURL, limit: 128 * 1_048_576)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TapeError.unreadable("index.jsonl UTF-8")
        }
        var rows: [(line: Int, sample: Sample)] = []
        var previousByKind: [String: Double] = [:]
        for (offset, line) in text.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = Self.number(obj["t"]), t >= 0,
                  let kind = (obj["kind"] as? String).flatMap(Kind.init(rawValue:)) else {
                throw TapeError.invalid("index.jsonl line \(offset + 1): malformed sample/time/kind")
            }
            switch kind {
            case .frame:
                guard let file = obj["file"] as? String,
                      Self.dimension(obj["w"]) != nil, Self.dimension(obj["h"]) != nil else {
                    throw TapeError.invalid("index.jsonl line \(offset + 1): frame file/dimensions")
                }
                _ = try Self.fileSize(Self.assetURL(file, root: root), limit: 64 * 1_048_576)
                if obj["depth"] != nil || obj["dw"] != nil || obj["dh"] != nil {
                    guard let depth = obj["depth"] as? String,
                          Self.dimension(obj["dw"]) != nil, Self.dimension(obj["dh"]) != nil else {
                        throw TapeError.invalid("index.jsonl line \(offset + 1): incomplete depth metadata")
                    }
                    _ = try Self.fileSize(Self.assetURL(depth, root: root), limit: 64 * 1_048_576)
                }
            case .imu:
                for (field, count) in [("q", 4), ("rot", 3), ("acc", 3), ("grav", 3)] {
                    guard let vector = obj[field] as? [Any], vector.count == count,
                          vector.allSatisfy({ Self.number($0) != nil }) else {
                        throw TapeError.invalid("index.jsonl line \(offset + 1): IMU \(field)")
                    }
                }
            case .event:
                guard let name = obj["name"] as? String, !name.isEmpty else {
                    throw TapeError.invalid("index.jsonl line \(offset + 1): event name")
                }
            }
            if kind != .event {
                if let previous = previousByKind[kind.rawValue], t <= previous {
                    throw TapeError.invalid("index.jsonl line \(offset + 1): \(kind.rawValue) time did not increase")
                }
                previousByKind[kind.rawValue] = t
            }
            rows.append((offset, Sample(t: t, kind: kind, fields: obj)))
        }
        guard !rows.isEmpty else { throw TapeError.invalid("index has no samples") }
        samples = rows.sorted {
            $0.sample.t == $1.sample.t ? $0.line < $1.line : $0.sample.t < $1.sample.t
        }.map { $0.sample }
        if let expected = meta["frames"] {
            guard let count = Self.number(expected), count == Double(samples.filter { $0.kind == .frame }.count) else {
                throw TapeError.invalid("frame count does not match finalized metadata")
            }
        }
        if let expected = meta["depthMaps"] {
            let actual = samples.filter { $0.kind == .frame && $0.fields["depth"] != nil }.count
            guard let count = Self.number(expected), count == Double(actual) else {
                throw TapeError.invalid("depth count does not match finalized metadata")
            }
        }
    }

    var frames: [Sample] { samples.filter { $0.kind == .frame } }
    /// Span of sampled data; metadata durationSeconds includes startup/idle time.
    var duration: TimeInterval { (samples.last?.t ?? 0) - (samples.first?.t ?? 0) }

    /// Blocking playback for tests/demos. Do not call realTime playback on the
    /// UI thread. Slow callbacks run late; their time is not added to later waits.
    func play(realTime: Bool = false, _ body: (Sample) throws -> Void) rethrows {
        let began = ProcessInfo.processInfo.systemUptime
        let origin = samples.first?.t ?? 0
        for sample in samples {
            if realTime {
                let remaining = sample.t - origin - (ProcessInfo.processInfo.systemUptime - began)
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            }
            try body(sample)
        }
    }

    func image(for sample: Sample) throws -> CGImage {
        guard sample.kind == .frame, let file = sample.fields["file"] as? String else {
            throw TapeError.missing("frame file")
        }
        let fileURL = try Self.assetURL(file, root: url)
        _ = try Self.fileSize(fileURL, limit: 64 * 1_048_576)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = Self.dimension(properties[kCGImagePropertyPixelWidth]),
              let height = Self.dimension(properties[kCGImagePropertyPixelHeight]),
              width * height <= 67_108_864,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == Self.dimension(sample.fields["w"]),
              image.height == Self.dimension(sample.fields["h"]) else {
            throw TapeError.unreadable("\(file): image/dimensions")
        }
        return image
    }

    /// JPEG replay becomes 32BGRA; apply the live pipeline's orientation and
    /// preprocessing explicitly. Original camera pixel/color attachments are lost.
    func pixelBuffer(for sample: Sample) throws -> CVPixelBuffer {
        let image = try image(for: sample)
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                  kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { throw TapeError.unreadable("pixel buffer") }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw TapeError.unreadable("pixel buffer lock")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw TapeError.unreadable("bitmap context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// Float32 metres, row-major. A bounded decoder avoids expanding beyond
    /// declared dimensions; unaligned loads support Data's storage alignment.
    func depth(for sample: Sample) throws -> (width: Int, height: Int, metres: [Float])? {
        guard sample.kind == .frame else { throw TapeError.invalid("depth requires a frame sample") }
        guard let file = sample.fields["depth"] as? String else { return nil }
        guard let w = Self.dimension(sample.fields["dw"]), let h = Self.dimension(sample.fields["dh"]),
              w * h <= 16_777_216 else { throw TapeError.invalid("depth dimensions") }
        let expected = w * h * MemoryLayout<Float>.size
        let packed = try Self.read(Self.assetURL(file, root: url), limit: 64 * 1_048_576)
        var raw = Data(count: expected + 1)
        let decoded = raw.withUnsafeMutableBytes { output in
            packed.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                                          input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == expected else { throw TapeError.unreadable("\(file): depth byte count") }
        let metres = raw.withUnsafeBytes { bytes in
            (0..<(w * h)).map { offset in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset * 4, as: UInt32.self)))
            }
        }
        return (w, h, metres)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func dimension(_ value: Any?) -> Int? {
        guard let n = number(value), n >= 1, n <= 16_384, n.rounded(.towardZero) == n else { return nil }
        return Int(n)
    }

    private static func assetURL(_ relative: String, root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !relative.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TapeError.invalid("unsafe asset path: \(relative)")
        }
        let result = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(root.path + "/") else { throw TapeError.invalid("asset escapes tape directory") }
        return result
    }

    private static func fileSize(_ file: URL, limit: Int) throws -> Int {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= limit else {
            throw TapeError.invalid("\(file.lastPathComponent): empty, not a file, or exceeds \(limit) bytes")
        }
        return bytes
    }

    private static func read(_ file: URL, limit: Int) throws -> Data {
        _ = try fileSize(file, limit: limit)
        let data = try Data(contentsOf: file)
        guard data.count <= limit else { throw TapeError.invalid("file grew beyond size limit") }
        return data
    }
}
