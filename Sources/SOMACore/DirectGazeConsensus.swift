import Foundation

public struct DirectGazeConsensusSample: Equatable, Sendable {
    public let rect: NormalizedRect
    public let evidence: VisualGazeEvidence
    public let directConfidence: Double
    public let capturedNS: UInt64

    public init(
        rect: NormalizedRect,
        evidence: VisualGazeEvidence,
        directConfidence: Double,
        capturedNS: UInt64
    ) {
        self.rect = rect
        self.evidence = evidence
        self.directConfidence = min(max(directConfidence, 0), 1)
        self.capturedNS = capturedNS
    }
}

/// Integrates direct-gaze confidence across a short series of independent
/// camera captures. This is perceptual accumulation, not a time cooldown: weak
/// off-axis samples cannot become contact merely by repeating, while strong
/// camera-directed samples cross the boundary within a few capture intervals.
public struct DirectGazeConsensus: Sendable {
    private struct Observation: Sendable {
        let capturedNS: UInt64
        let confidence: Double
    }

    private struct Track: Sendable {
        var rect: NormalizedRect
        var lastCaptureNS: UInt64
        var observations: [Observation]
    }

    private let requiredIndependentSamples: Int
    private let minimumSustainedNS: UInt64
    private let maximumInterSampleNS: UInt64
    private let integrationWindowNS: UInt64
    private let minimumMeanConfidence: Double
    private let minimumSampleConfidence: Double
    private var tracks: [Track] = []

    public init(
        requiredIndependentSamples: Int = 3,
        minimumSustainedMilliseconds: UInt64 = 140,
        maximumInterSampleMilliseconds: UInt64 = 250,
        integrationWindowMilliseconds: UInt64 = 500,
        minimumMeanConfidence: Double = 0.62,
        minimumSampleConfidence: Double = 0.50
    ) {
        precondition(requiredIndependentSamples >= 2)
        precondition(minimumSustainedMilliseconds > 0)
        precondition(maximumInterSampleMilliseconds > 0)
        precondition(integrationWindowMilliseconds >= minimumSustainedMilliseconds)
        precondition((0...1).contains(minimumMeanConfidence))
        precondition((0...1).contains(minimumSampleConfidence))
        self.requiredIndependentSamples = requiredIndependentSamples
        self.minimumSustainedNS = minimumSustainedMilliseconds * 1_000_000
        self.maximumInterSampleNS = maximumInterSampleMilliseconds * 1_000_000
        self.integrationWindowNS = integrationWindowMilliseconds * 1_000_000
        self.minimumMeanConfidence = minimumMeanConfidence
        self.minimumSampleConfidence = minimumSampleConfidence
    }

    /// Returns one stabilized state per input sample, preserving input order.
    /// Averted or unavailable evidence immediately breaks a direct-gaze run.
    public mutating func stabilize(_ samples: [DirectGazeConsensusSample]) -> [VisualGazeEvidence] {
        guard !samples.isEmpty else {
            // A detector miss carries no evidence that the person looked
            // away. Preserve the pending run without advancing it; the next
            // actual capture will prune it when the inter-sample gap exceeds
            // `maximumInterSampleNS`. This tolerates one dropped landmark
            // frame while never letting absence authorize contact.
            return []
        }

        let newestCaptureNS = samples.map(\.capturedNS).max() ?? 0
        tracks.removeAll { track in
            newestCaptureNS > track.lastCaptureNS
                && newestCaptureNS - track.lastCaptureNS > maximumInterSampleNS
        }

        var claimedTrackIndices = Set<Int>()
        return samples.map { sample in
            let trackIndex = tracks.indices
                .filter { !claimedTrackIndices.contains($0) }
                .max { lhs, rhs in
                    overlap(tracks[lhs].rect, sample.rect) < overlap(tracks[rhs].rect, sample.rect)
                }
                .flatMap { overlap(tracks[$0].rect, sample.rect) >= 0.10 ? $0 : nil }

            let index: Int
            if let trackIndex {
                index = trackIndex
                claimedTrackIndices.insert(trackIndex)
            } else {
                tracks.append(Track(
                    rect: sample.rect,
                    lastCaptureNS: 0,
                    observations: []
                ))
                index = tracks.index(before: tracks.endIndex)
                claimedTrackIndices.insert(index)
            }

            var track = tracks[index]
            let isIndependentCapture = sample.capturedNS > track.lastCaptureNS
            switch sample.evidence {
            case .direct:
                if isIndependentCapture {
                    if track.lastCaptureNS > 0,
                       sample.capturedNS - track.lastCaptureNS > maximumInterSampleNS {
                        track.observations.removeAll(keepingCapacity: true)
                    }
                    track.observations.append(Observation(
                        capturedNS: sample.capturedNS,
                        confidence: sample.directConfidence
                    ))
                    track.observations.removeAll { observation in
                        sample.capturedNS > observation.capturedNS
                            && sample.capturedNS - observation.capturedNS > integrationWindowNS
                    }
                    track.lastCaptureNS = sample.capturedNS
                }
            case .averted, .unavailable:
                track.observations.removeAll(keepingCapacity: true)
                if isIndependentCapture {
                    track.lastCaptureNS = sample.capturedNS
                }
            }
            track.rect = sample.rect
            tracks[index] = track

            guard sample.evidence == .direct else { return sample.evidence }
            guard track.observations.count >= requiredIndependentSamples,
                  let first = track.observations.first,
                  let last = track.observations.last,
                  last.capturedNS >= first.capturedNS,
                  last.capturedNS - first.capturedNS >= minimumSustainedNS else {
                return .unavailable
            }
            let meanConfidence = track.observations.reduce(0) { $0 + $1.confidence }
                / Double(track.observations.count)
            let weakestConfidence = track.observations.map(\.confidence).min() ?? 0
            return meanConfidence >= minimumMeanConfidence
                && weakestConfidence >= minimumSampleConfidence
                ? .direct
                : .unavailable
        }
    }

    private func overlap(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
