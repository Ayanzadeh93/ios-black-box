//
//  TapeReplayTests.swift — ios-sensor-tape skill
//
//  The three tests every tape deserves. Replace `run(_:)` with a call into
//  your own pipeline (detector, classifier, depth, tracker...), returning
//  something Equatable that describes its output for one frame.
//
//      TEST_RUNNER_SENSOR_TAPE=/path/to/tape-… xcodebuild test … \
//        -only-testing:"YourAppTests/TapeReplayTests"
//

import CoreVideo
import Foundation
import Testing
@testable import YourApp

struct TapeReplayTests {
    static let tapeURL: URL? = ProcessInfo.processInfo.environment["SENSOR_TAPE"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// Your pipeline, one frame in, a comparable description out.
    /// `strict` is the deliberately changed setting used by the "has teeth" test.
    func run(_ buffer: CVPixelBuffer, strict: Bool = false) -> [String] {
        // e.g. detector.detect(buffer, minConfidence: strict ? 0.7 : 0.3).map(\.description).sorted()
        []
    }

    func replay(_ tape: TapePlayer, strict: Bool = false) throws -> [[String]] {
        try tape.frames.prefix(40).map { try run(tape.pixelBuffer(for: $0), strict: strict) }
    }

    @Test(.enabled(if: tapeURL != nil)) func wellFormed() throws {
        let tape = try TapePlayer(url: try #require(Self.tapeURL))
        #expect(!tape.frames.isEmpty)
        #expect(zip(tape.samples, tape.samples.dropFirst()).allSatisfy { $0.t <= $1.t })
        _ = try tape.image(for: try #require(tape.frames.first))
    }

    @Test(.enabled(if: tapeURL != nil)) func deterministic() throws {
        let tape = try TapePlayer(url: try #require(Self.tapeURL))
        let first = try replay(tape), second = try replay(tape)
        #expect(first.joined().count > 0, "the tape should contain something your pipeline reacts to")
        #expect(first == second)
    }

    @Test(.enabled(if: tapeURL != nil)) func hasTeeth() throws {
        let tape = try TapePlayer(url: try #require(Self.tapeURL))
        #expect(try replay(tape) != replay(tape, strict: true),
                "a changed setting must change the output, or the comparison proves nothing")
    }
}
