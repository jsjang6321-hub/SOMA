import Testing
@testable import SOMACore

struct DirectGazeConsensusTests {
    private let face = NormalizedRect(x: 0.3, y: 0.2, width: 0.2, height: 0.3)

    @Test
    func oneDirectCaptureCannotAuthorizeContact() {
        var consensus = DirectGazeConsensus()

        let state = consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.90, capturedNS: 1_000_000_000),
        ])

        #expect(state == [.unavailable])
    }

    @Test
    func repeatedUseOfTheSameCaptureDoesNotBuildConsensus() {
        var consensus = DirectGazeConsensus()
        let sample = DirectGazeConsensusSample(
            rect: face,
            evidence: .direct,
            directConfidence: 0.90,
            capturedNS: 1_000_000_000
        )

        #expect(consensus.stabilize([sample]) == [.unavailable])
        #expect(consensus.stabilize([sample]) == [.unavailable])
    }

    @Test
    func sustainedHighConfidenceCapturesAuthorizeContact() {
        var consensus = DirectGazeConsensus()

        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.90, capturedNS: 1_000_000_000),
        ]) == [.unavailable])
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.88, capturedNS: 1_080_000_000),
        ]) == [.unavailable])
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.92, capturedNS: 1_160_000_000),
        ]) == [.direct])
    }

    @Test
    func briefDetectorMissDoesNotEraseIndependentDirectCaptures() {
        var consensus = DirectGazeConsensus()

        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.90, capturedNS: 1_000_000_000),
        ]) == [.unavailable])
        #expect(consensus.stabilize([]).isEmpty)
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.88, capturedNS: 1_080_000_000),
        ]) == [.unavailable])
        #expect(consensus.stabilize([]).isEmpty)
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.92, capturedNS: 1_160_000_000),
        ]) == [.direct])
    }

    @Test
    func detectorMissCannotBridgeAStaleDirectRun() {
        var consensus = DirectGazeConsensus()

        _ = consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.90, capturedNS: 1_000_000_000),
        ])
        #expect(consensus.stabilize([]).isEmpty)
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.90, capturedNS: 1_400_000_000),
        ]) == [.unavailable])
    }

    @Test
    func observedCenteredContactConfidenceStillAuthorizesPromptly() {
        var consensus = DirectGazeConsensus()
        let confidences = [0.65, 0.63, 0.66]

        for (index, confidence) in confidences.enumerated() {
            let state = consensus.stabilize([
                .init(
                    rect: face,
                    evidence: .direct,
                    directConfidence: confidence,
                    capturedNS: 1_000_000_000 + UInt64(index) * 80_000_000
                ),
            ])
            #expect(state == (index == confidences.count - 1 ? [.direct] : [.unavailable]))
        }
    }

    @Test
    func repeatedWeakOffAxisEvidenceNeverAuthorizesContact() {
        var consensus = DirectGazeConsensus()

        for index in 0..<8 {
            #expect(consensus.stabilize([
                .init(
                    rect: face,
                    evidence: .direct,
                    directConfidence: index.isMultiple(of: 2) ? 0.38 : 0.48,
                    capturedNS: 1_000_000_000 + UInt64(index) * 80_000_000
                ),
            ]) == [.unavailable])
        }
    }

    @Test
    func avertedCaptureBreaksTheDirectRun() {
        var consensus = DirectGazeConsensus()

        _ = consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.90, capturedNS: 1_000_000_000),
        ])
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .averted, directConfidence: 0, capturedNS: 1_080_000_000),
        ]) == [.averted])
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, directConfidence: 0.90, capturedNS: 1_160_000_000),
        ]) == [.unavailable])
    }
}
