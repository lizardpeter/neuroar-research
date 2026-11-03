import XCTest
@testable import GeometryCore

final class NaturalFaceRegistrationTests: XCTestCase {
    private let face: [NaturalFacePoint] = [
        .init(feature: .leftEyeCenter, worldMeters: .init(-0.032, 0.018, 0.006)),
        .init(feature: .rightEyeCenter, worldMeters: .init(0.032, 0.018, 0.006)),
        .init(feature: .noseTip, worldMeters: .init(0, -0.005, 0.034)),
        .init(feature: .mouthCenter, worldMeters: .init(0, -0.048, 0.017))
    ]

    func testNaturalFeatureRegistrationWithoutPhysicalFiducials() throws {
        let offset = Point3(0.11, -0.03, -0.45)
        let observed = face.reversed().map { NaturalFacePoint(feature: $0.feature, worldMeters: $0.worldMeters + offset) }
        let fit = try NaturalFaceRegistration.fit(mri: face, camera: observed)
        XCTAssertLessThan(fit.rmsMeters, 0.00001)
        XCTAssertLessThan((fit.transform.translationMeters - offset).norm, 0.00001)
        XCTAssertEqual(fit.matchedFeatures, 4)
    }

    func testExplicitAnatomicNamesAndMillimeterConversion() throws {
        let landmarks = [
            StudyLandmark(id: "one", name: "left eye center", pointMm: .init(-32, 18, 6)),
            StudyLandmark(id: "two", name: "RightEyeCenter", pointMm: .init(32, 18, 6)),
            StudyLandmark(id: "three", name: "Nose Tip", pointMm: .init(0, -5, 34)),
            StudyLandmark(id: "four", name: "random chin", pointMm: .init(0, -48, 17))
        ]
        let result = try NaturalFaceRegistration.mriFeatures(landmarks)
        XCTAssertEqual(result.count, 3)
        XCTAssertLessThan((result[0].worldMeters - Point3(-0.032, 0.018, 0.006)).norm, 1e-12)
    }

    func testRejectDuplicateFeatureAndWrongHead() throws {
        XCTAssertThrowsError(try NaturalFaceRegistration.fit(mri: face,
            camera: face + [face[0]]))
        let shifted = face.map { NaturalFacePoint(feature: $0.feature,
            worldMeters: Point3($0.worldMeters.x + ($0.feature == .noseTip ? 0.08 : 0),
                                $0.worldMeters.y, $0.worldMeters.z)) }
        XCTAssertThrowsError(try NaturalFaceRegistration.fit(mri: face, camera: shifted))
    }

    func testMotionAndLossOfFeature() throws {
        let moved = face.map { NaturalFacePoint(feature: $0.feature,
            worldMeters: $0.worldMeters + Point3(0.017, 0.006, 0.009)) }
        let delta = try NaturalFaceRegistration.motion(reference: face, observed: moved)
        XCTAssertLessThan((delta.transform.translationMeters - Point3(0.017, 0.006, 0.009)).norm, 0.00001)
        XCTAssertThrowsError(try NaturalFaceRegistration.motion(reference: face,
            observed: Array(moved.prefix(2))))
    }

    func testRejectsLargeJumpAndInvalidMRIName() throws {
        let far = face.map { NaturalFacePoint(feature: $0.feature,
            worldMeters: $0.worldMeters + Point3(0.31, 0, 0)) }
        XCTAssertThrowsError(try NaturalFaceRegistration.motion(reference: face, observed: far))
        XCTAssertNil(NaturalFaceFeature.fromMRIName("nose bridge"))
        XCTAssertNil(NaturalFaceFeature.fromMRIName("left brow"))
    }
}
