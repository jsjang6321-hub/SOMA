import Testing
@testable import SOMACore

struct LandmarkGazeClassifierTests {
    @Test
    func belowEyeLevelCameraUsesCalibratedVerticalRay() {
        let lowerCameraEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.10,
            pupilOffsetY: 0.10,
            signedPupilOffsetY: -0.10,
            apertureRatio: 0.36
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: nil,
            leftEye: lowerCameraEye,
            rightEye: lowerCameraEye
        ) == .averted)
        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: nil,
            leftEye: lowerCameraEye,
            rightEye: lowerCameraEye,
            expectedDirectPupilOffsetY: -0.10
        ) == .direct)
    }

    @Test
    func belowEyeLevelCalibrationStillRejectsFurtherDownwardGaze() {
        let phoneEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.10,
            pupilOffsetY: 0.16,
            signedPupilOffsetY: -0.16,
            apertureRatio: 0.36
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: nil,
            leftEye: phoneEye,
            rightEye: phoneEye,
            expectedDirectPupilOffsetY: -0.10
        ) == .averted)
    }

    @Test
    func directCameraGazeRequiresBilateralOpenCenteredEyes() {
        let assessment = LandmarkGazeClassifier.assess(
            yaw: 0,
            pitch: nil,
            leftEye: EyeLandmarkGeometry(
                pupilOffsetX: 0.028,
                pupilOffsetY: 0.195,
                signedPupilOffsetY: 0.195,
                apertureRatio: 0.309
            ),
            rightEye: EyeLandmarkGeometry(
                pupilOffsetX: 0.020,
                pupilOffsetY: 0.105,
                signedPupilOffsetY: 0.105,
                apertureRatio: 0.355
            )
        )

        #expect(assessment.evidence == .direct)
        #expect(assessment.directConfidence > 0.80)
    }

    @Test
    func downwardPhoneGazeIsAvertedEvenWhenPupilsAppearCentered() {
        let state = LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: nil,
            leftEye: EyeLandmarkGeometry(
                pupilOffsetX: 0.147,
                pupilOffsetY: 0.007,
                signedPupilOffsetY: -0.007,
                apertureRatio: 0.265
            ),
            rightEye: EyeLandmarkGeometry(
                pupilOffsetX: 0.055,
                pupilOffsetY: 0.141,
                signedPupilOffsetY: -0.141,
                apertureRatio: 0.238
            )
        )

        #expect(state == .averted)
    }

    @Test
    func pronouncedFaceTurnCannotBecomeDirectGaze() {
        let openEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.05,
            pupilOffsetY: 0.10,
            signedPupilOffsetY: 0.10,
            apertureRatio: 0.33
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: .pi / 4,
            pitch: nil,
            leftEye: openEye,
            rightEye: openEye
        ) == .averted)
    }

    @Test
    func missingHeadPoseRemainsUnavailable() {
        let openEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.05,
            pupilOffsetY: 0.10,
            signedPupilOffsetY: 0.10,
            apertureRatio: 0.33
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: nil,
            pitch: nil,
            leftEye: openEye,
            rightEye: openEye
        ) == .unavailable)
    }

    @Test
    func slightlyStricterThresholdRejectsMarginalPupilCentering() {
        let marginalEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.57,
            pupilOffsetY: 0.20,
            signedPupilOffsetY: 0.20,
            apertureRatio: 0.33
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: 0,
            leftEye: marginalEye,
            rightEye: marginalEye,
            pupilCenteringScale: 1.0
        ) == .direct)
        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: 0,
            leftEye: marginalEye,
            rightEye: marginalEye,
            pupilCenteringScale: 0.9
        ) == .averted)
    }

    @Test
    func sustainedDownwardPupilDisplacementCannotBecomeDirectGaze() {
        let downwardEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.12,
            pupilOffsetY: 0.16,
            signedPupilOffsetY: -0.16,
            apertureRatio: 0.36
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: nil,
            leftEye: downwardEye,
            rightEye: downwardEye
        ) == .averted)
    }

    @Test
    func observedOffAxisFalsePositiveHasInsufficientContactConfidence() {
        let first = EyeLandmarkGeometry(
            pupilOffsetX: 0.356,
            pupilOffsetY: 0.234,
            signedPupilOffsetY: 0.183,
            apertureRatio: 0.354
        )
        let second = EyeLandmarkGeometry(
            pupilOffsetX: 0.305,
            pupilOffsetY: 0.166,
            signedPupilOffsetY: 0.156,
            apertureRatio: 0.321
        )

        let firstAssessment = LandmarkGazeClassifier.assess(
            yaw: 0,
            pitch: nil,
            leftEye: first,
            rightEye: first,
            pupilCenteringScale: 0.9
        )
        let secondAssessment = LandmarkGazeClassifier.assess(
            yaw: 0,
            pitch: nil,
            leftEye: second,
            rightEye: second,
            pupilCenteringScale: 0.9
        )

        #expect(firstAssessment.evidence == .direct)
        #expect(secondAssessment.evidence == .direct)
        #expect(firstAssessment.directConfidence < 0.60)
        #expect(secondAssessment.directConfidence < 0.60)
    }

    @Test
    func observedCenteredContactRetainsSufficientConfidence() {
        let first = EyeLandmarkGeometry(
            pupilOffsetX: 0.176,
            pupilOffsetY: 0.191,
            signedPupilOffsetY: 0.174,
            apertureRatio: 0.395
        )
        let second = EyeLandmarkGeometry(
            pupilOffsetX: 0.161,
            pupilOffsetY: 0.266,
            signedPupilOffsetY: 0.247,
            apertureRatio: 0.404
        )

        let assessments = [first, second].map { eye in
            LandmarkGazeClassifier.assess(
                yaw: 0,
                pitch: nil,
                leftEye: eye,
                rightEye: eye,
                pupilCenteringScale: 0.9
            )
        }

        #expect(assessments.allSatisfy { $0.evidence == .direct })
        #expect(assessments.allSatisfy { $0.directConfidence >= 0.62 })
    }
}
