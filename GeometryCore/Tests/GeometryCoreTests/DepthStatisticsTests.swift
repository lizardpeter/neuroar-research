import XCTest
@testable import GeometryCore

final class DepthStatisticsTests: XCTestCase {
    func testMedianRejectsBackgroundAndPreservesHeadDepth() {
        let readings:[DepthObservation] = [
            .init(meters:0.505,confidence:2), .init(meters:0.500,confidence:2),
            .init(meters:0.497,confidence:1), .init(meters:2.0,confidence:2),
            .init(meters:0.508,confidence:2), .init(meters:0.501,confidence:2),
            .init(meters:0.499,confidence:2), .init(meters:0.506,confidence:2),
            .init(meters:0.504,confidence:2)
        ]
        let result=DepthStatistics.estimate(readings)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.meters,0.5025,accuracy:0.005)
        XCTAssertEqual(result!.acceptedCount,8)
    }

    func testInsufficientConfidentSamplesAreRejected() {
        let readings:[DepthObservation] = [
            .init(meters:0.5,confidence:0), .init(meters:0.6,confidence:0),
            .init(meters:0.5,confidence:2), .init(meters:Float.nan,confidence:2)
        ]
        XCTAssertNil(DepthStatistics.estimate(readings))
    }

    func testRejectsWidelySeparatedReadings() {
        let readings:[DepthObservation] = (0..<9).map {
            DepthObservation(meters:0.2+Float($0)*0.2,confidence:2)
        }
        XCTAssertNil(DepthStatistics.estimate(readings))
    }
}
