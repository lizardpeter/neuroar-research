import XCTest
@testable import GeometryCore

final class OverlayTrackingGateTests: XCTestCase {
    func testNormalRecentNaturalFaceCanShowResearchOverlay() {
        let result = OverlayTrackingGate.source(cameraNormal: true, headBound: true, hasPose: true,
            faceVisible: true, surfaceTracking: false, secondsSinceFace: 0.12, secondsSinceMotion: 0.12)
        XCTAssertEqual(result, .naturalFace)
    }

    func testSurfaceContinuationRequiresRecentMotionAndInitialFace() {
        XCTAssertEqual(OverlayTrackingGate.source(cameraNormal: true, headBound: true, hasPose: true,
            faceVisible: false, surfaceTracking: true, secondsSinceFace: 0.85, secondsSinceMotion: 0.05), .shortTermSurface)
        XCTAssertEqual(OverlayTrackingGate.source(cameraNormal: true, headBound: true, hasPose: true,
            faceVisible: false, surfaceTracking: true, secondsSinceFace: 1.81, secondsSinceMotion: 0.01), .hidden)
        XCTAssertEqual(OverlayTrackingGate.source(cameraNormal: true, headBound: true, hasPose: true,
            faceVisible: false, surfaceTracking: true, secondsSinceFace: 0.70, secondsSinceMotion: 0.45), .hidden)
    }

    func testLostCameraOrMissingPoseAlwaysHides() {
        XCTAssertEqual(OverlayTrackingGate.source(cameraNormal: false, headBound: true, hasPose: true,
            faceVisible: true, surfaceTracking: false, secondsSinceFace: 0, secondsSinceMotion: 0), .hidden)
        XCTAssertEqual(OverlayTrackingGate.source(cameraNormal: true, headBound: true, hasPose: false,
            faceVisible: true, surfaceTracking: false, secondsSinceFace: 0, secondsSinceMotion: 0), .hidden)
        XCTAssertEqual(OverlayTrackingGate.source(cameraNormal: true, headBound: false, hasPose: true,
            faceVisible: true, surfaceTracking: false, secondsSinceFace: 0, secondsSinceMotion: 0), .hidden)
    }

    func testStaleAndNonfiniteObservationsHide() {
        for age in [-0.001, 0.401, .infinity, .nan] {
            XCTAssertEqual(OverlayTrackingGate.source(cameraNormal: true, headBound: true, hasPose: true,
                faceVisible: true, surfaceTracking: false, secondsSinceFace: age, secondsSinceMotion: age), .hidden)
        }
    }
}
