//
//  TapeReplayTests.swift — ios-sensor-tape skill
//
//  Adapt this template to your pipeline and a short, labelled fixture.
//  makePipeline must create fresh state for EACH replay, returning a closure
//  whose comparable outputs reflect your pipeline (vision, tracking, etc.).
//
//      TEST_RUNNER_SENSOR_TAPE=/path/to/tape-… \
//        TEST_RUNNER_REQUIRE_SENSOR_TAPE=1 xcodebuild test … \
//        -only-testing:"YourAppTests/TapeReplayTests"
//

import CoreVideo
import Foundation
import Testing
@testable import YourApp

struct TapeReplayTests {
    static let tapeURL: URL? = ProcessInfo.processInfo.environment["SENSOR_TAPE"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    enum SetupError: Error { case connectYourPipeline }

    /// Construct/reset the pipeline here; do not share a singleton across runs.
    /// Match live orientation and preprocessing. Pick a deliberate setting
    /// change and fixture that should alter output; do not assume every input
    /// is sensitive to a confidence-threshold change.
    func makePipeline(strict: Bool) throws -> (CVPixelBuffer) throws -> [String] {
        // let detector = YourDetector(minConfidence: strict ? 0.7 : 0.3)
        // return { detector.detect($0).map(\.description).sorted() }
        throw SetupError.connectYourPipeline
    }

    func replay(_ tape: TapePlayer, strict: Bool = false) throws -> [[String]] {
        let run = try makePipeline(strict: strict)
        return try tape.frames.map { try run(tape.pixelBuffer(for: $0)) }
    }

    /// Enable this requirement in CI so a missing fixture cannot silently skip
    /// the replay checks. The remaining tests stay optional for ordinary builds.
    @Test func requiredFixtureIsConfigured() throws {
        if ProcessInfo.processInfo.environment["REQUIRE_SENSOR_TAPE"] == "1" {
            _ = try #require(Self.tapeURL, "set SENSOR_TAPE to the fixture directory")
        }
    }

    @Test(.enabled(if: tapeURL != nil)) func wellFormed() throws {
        let tape = try TapePlayer(url: try #require(Self.tapeURL))
        #expect(!tape.frames.isEmpty)
        // Decode every asset, not just the first frame. TapePlayer already
        // rejects malformed rows, unsafe paths and incomplete metadata.
        for sample in tape.frames {
            _ = try tape.image(for: sample)
            _ = try tape.depth(for: sample)
        }
    }

    @Test(.enabled(if: tapeURL != nil)) func deterministic() throws {
        let tape = try TapePlayer(url: try #require(Self.tapeURL))
        let first = try replay(tape), second = try replay(tape)
        #expect(first.joined().count > 0, "choose a labelled fixture with a known expected result")
        // Replace exact equality with a documented numeric tolerance when the
        // model/runtime is nondeterministic. Check labels/expected outputs too.
        #expect(first == second)
    }

    @Test(.enabled(if: tapeURL != nil)) func hasTeeth() throws {
        let tape = try TapePlayer(url: try #require(Self.tapeURL))
        #expect(try replay(tape) != replay(tape, strict: true),
                "a changed setting must change the output, or the comparison proves nothing")
    }
}
