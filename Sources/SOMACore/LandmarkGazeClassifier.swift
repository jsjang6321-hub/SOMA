import Foundation

/// Camera-independent geometry extracted from one eye landmark set.
public struct EyeLandmarkGeometry: Equatable, Sendable {
    /// Absolute pupil displacement from the eye contour centre, normalized by
    /// half of the contour width.
    public let pupilOffsetX: Double
    /// Absolute pupil displacement from the eye contour centre, normalized by
    /// half of the contour height.
    public let pupilOffsetY: Double
    /// Signed vertical pupil displacement in Vision landmark coordinates,
    /// normalized by half of the contour height. Positive values point toward
    /// the upper eyelid; negative values point toward the lower eyelid.
    public let signedPupilOffsetY: Double
    /// Eye-contour height divided by width. A downward glance compresses this
    /// aperture even when a landmark detector recentres the pupil and contour
    /// together.
    public let apertureRatio: Double

    public init(
        pupilOffsetX: Double,
        pupilOffsetY: Double,
        signedPupilOffsetY: Double,
        apertureRatio: Double
    ) {
        self.pupilOffsetX = pupilOffsetX
        self.pupilOffsetY = pupilOffsetY
        self.signedPupilOffsetY = signedPupilOffsetY
        self.apertureRatio = apertureRatio
    }
}

/// One-frame gaze interpretation. `evidence` carries hard geometric facts,
/// while `directConfidence` preserves how centrally the pupils and face pose
/// support camera-directed gaze. Temporal admission consumes the confidence;
/// a permissive binary boundary alone must never authorize a conversation.
public struct LandmarkGazeAssessment: Equatable, Sendable {
    public let evidence: VisualGazeEvidence
    public let directConfidence: Double

    public init(evidence: VisualGazeEvidence, directConfidence: Double) {
        self.evidence = evidence
        self.directConfidence = min(max(directConfidence, 0), 1)
    }
}

/// Reduces bilateral eye geometry and face pose into transient gaze evidence.
/// Pupil centring alone is insufficient because eyelid motion can translate
/// the measured pupil and eye contour together during a downward glance.
public enum LandmarkGazeClassifier {
    public static func classify(
        yaw: Double?,
        pitch: Double?,
        leftEye: EyeLandmarkGeometry,
        rightEye: EyeLandmarkGeometry,
        pupilCenteringScale: Double = 1,
        expectedDirectPupilOffsetY: Double = 0,
        minimumMeanEyeAperture: Double = 0.27,
        minimumMeanSignedPupilOffsetY: Double = -0.05
    ) -> VisualGazeEvidence {
        assess(
            yaw: yaw,
            pitch: pitch,
            leftEye: leftEye,
            rightEye: rightEye,
            pupilCenteringScale: pupilCenteringScale,
            expectedDirectPupilOffsetY: expectedDirectPupilOffsetY,
            minimumMeanEyeAperture: minimumMeanEyeAperture,
            minimumMeanSignedPupilOffsetY: minimumMeanSignedPupilOffsetY
        ).evidence
    }

    public static func assess(
        yaw: Double?,
        pitch: Double?,
        leftEye: EyeLandmarkGeometry,
        rightEye: EyeLandmarkGeometry,
        pupilCenteringScale: Double = 1,
        expectedDirectPupilOffsetY: Double = 0,
        minimumMeanEyeAperture: Double = 0.27,
        minimumMeanSignedPupilOffsetY: Double = -0.05
    ) -> LandmarkGazeAssessment {
        let values = [
            leftEye.pupilOffsetX,
            leftEye.pupilOffsetY,
            leftEye.signedPupilOffsetY,
            leftEye.apertureRatio,
            rightEye.pupilOffsetX,
            rightEye.pupilOffsetY,
            rightEye.signedPupilOffsetY,
            rightEye.apertureRatio,
            pupilCenteringScale,
            expectedDirectPupilOffsetY,
            minimumMeanEyeAperture,
            minimumMeanSignedPupilOffsetY,
        ]
        guard values.allSatisfy(\.isFinite),
              pupilCenteringScale > 0,
              (-0.35 ... 0.35).contains(expectedDirectPupilOffsetY),
              minimumMeanEyeAperture > 0,
              let yaw,
              yaw.isFinite else {
            return LandmarkGazeAssessment(evidence: .unavailable, directConfidence: 0)
        }

        if abs(yaw) > 0.65 {
            return LandmarkGazeAssessment(evidence: .averted, directConfidence: 0)
        }
        if let pitch, pitch.isFinite, abs(pitch) > 0.45 {
            return LandmarkGazeAssessment(evidence: .averted, directConfidence: 0)
        }

        let horizontalLimit = 0.60 * pupilCenteringScale
        let verticalLimit = 0.50 * pupilCenteringScale
        let pupilIsCentered = [leftEye, rightEye].allSatisfy { eye in
            eye.pupilOffsetX <= horizontalLimit
                && abs(eye.signedPupilOffsetY - expectedDirectPupilOffsetY) <= verticalLimit
        }
        guard pupilIsCentered else {
            return LandmarkGazeAssessment(evidence: .averted, directConfidence: 0)
        }

        // The previous absolute-only Y offset discarded the distinction
        // between looking up and looking down. A sustained glance toward a
        // phone could therefore look geometrically identical to camera gaze.
        // Bilateral mean displacement is more stable than rejecting one noisy
        // pupil independently while preserving the missing direction.
        let meanSignedPupilOffsetY = (
            leftEye.signedPupilOffsetY + rightEye.signedPupilOffsetY
        ) / 2
        let meanVerticalResidual = meanSignedPupilOffsetY - expectedDirectPupilOffsetY
        guard meanVerticalResidual >= minimumMeanSignedPupilOffsetY else {
            return LandmarkGazeAssessment(evidence: .averted, directConfidence: 0)
        }

        let meanAperture = (leftEye.apertureRatio + rightEye.apertureRatio) / 2
        let minimumBilateralAperture = minimumMeanEyeAperture * 0.70
        guard meanAperture >= minimumMeanEyeAperture,
              min(leftEye.apertureRatio, rightEye.apertureRatio) >= minimumBilateralAperture else {
            return LandmarkGazeAssessment(evidence: .averted, directConfidence: 0)
        }

        let maximumHorizontalOffset = max(leftEye.pupilOffsetX, rightEye.pupilOffsetX)
        let maximumVerticalOffset = max(
            abs(leftEye.signedPupilOffsetY - expectedDirectPupilOffsetY),
            abs(rightEye.signedPupilOffsetY - expectedDirectPupilOffsetY)
        )
        let horizontalSupport = max(0, 1 - maximumHorizontalOffset / horizontalLimit)
        let verticalSupport = max(0, 1 - maximumVerticalOffset / verticalLimit)
        let pupilSupport = horizontalSupport * 0.75 + verticalSupport * 0.25
        let yawSupport = max(0, 1 - abs(yaw) / 0.65)
        let pitchSupport = pitch.map { max(0, 1 - abs($0) / 0.45) } ?? 1
        return LandmarkGazeAssessment(
            evidence: .direct,
            directConfidence: min(pupilSupport, yawSupport, pitchSupport)
        )
    }
}
