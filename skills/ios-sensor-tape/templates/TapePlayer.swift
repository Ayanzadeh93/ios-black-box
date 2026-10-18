//
//  TapePlayer.swift — ios-sensor-tape skill
//
//  Replays a tape recorded by SensorTape, in time order, so a real walk can
//  drive your pipeline inside XCTest / Swift Testing — the same input, every run.
//
//      let tape = try TapePlayer(url: tapeURL)
//      for sample in tape.samples where sample.kind == .frame {
//          let buffer = try tape.pixelBuffer(for: sample)   // feed your detector
//          let depth = try tape.depth(for: sample)          // optional Float32 map
//      }
//
//  Add this file to your test target (and the app target if you replay in-app).
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

struct TapePlayer {
    enum Kind: String { case frame, imu, event }

    struct Sample {
        let t: TimeInterval
        let kind: Kind
        /// The raw JSON line: frame size and file names, IMU vectors, or your event fields.
        let fields: [String: Any]
        var name: String? { fields["name"] as? String }
    }

    enum TapeError: Error, CustomStringConvertible {
        case missing(String), unreadable(String)
        var description: String {
            switch self {
            case .missing(let what): return "tape is missing \(what)"
            case .unreadable(let what): return "cannot read \(what)"
            }
        }
    }

    let url: URL
    let meta: [String: Any]
    /// Every sample, sorted by time (frames, IMU and events interleaved).
    let samples: [Sample]

    init(url: URL) throws {
        self.url = url
        guard let metaData = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
              let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        else { throw TapeError.missing("meta.json") }
        self.meta = meta
        guard let text = try? String(contentsOf: url.appendingPathComponent("index.jsonl"), encoding: .utf8)
        else { throw TapeError.missing("index.jsonl") }
        var rows: [Sample] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = obj["t"] as? Double,
                  let kind = (obj["kind"] as? String).flatMap(Kind.init(rawValue:)) else { continue }
            rows.append(Sample(t: t, kind: kind, fields: obj))
        }
        samples = rows.sorted { $0.t < $1.t }
    }

    var frames: [Sample] { samples.filter { $0.kind == .frame } }
    var duration: TimeInterval { (samples.last?.t ?? 0) - (samples.first?.t ?? 0) }

    /// Calls `body` for each sample in time order. Pass `realTime: true` to
    /// sleep between samples (for in-app demos); tests should leave it off.
    func play(realTime: Bool = false, _ body: (Sample) throws -> Void) rethrows {
        var previous: TimeInterval?
        for sample in samples {
            if realTime, let previous, sample.t > previous {
                Thread.sleep(forTimeInterval: sample.t - previous)
            }
            previous = sample.t
            try body(sample)
        }
    }

    // MARK: Frames

    func image(for sample: Sample) throws -> CGImage {
        guard let file = sample.fields["file"] as? String else { throw TapeError.missing("frame file") }
        let fileURL = url.appendingPathComponent(file)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TapeError.unreadable(file) }
        return image
    }

    /// A 32BGRA pixel buffer, the format most Vision / Core ML pipelines accept.
    func pixelBuffer(for sample: Sample) throws -> CVPixelBuffer {
        let image = try image(for: sample)
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                  kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { throw TapeError.unreadable("pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
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

    // MARK: Depth

    /// The Float32 depth map saved with this frame, if any (metres, row-major).
    func depth(for sample: Sample) throws -> (width: Int, height: Int, metres: [Float])? {
        guard let file = sample.fields["depth"] as? String,
              let w = sample.fields["dw"] as? Int, let h = sample.fields["dh"] as? Int else { return nil }
        guard let packed = try? Data(contentsOf: url.appendingPathComponent(file)),
              let raw = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              raw.count == w * h * 4
        else { throw TapeError.unreadable(file) }
        let metres = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (w, h, metres)
    }
}
