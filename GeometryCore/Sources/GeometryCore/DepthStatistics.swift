import Foundation

/// Portable quality check for LiDAR neighborhoods. This is an engineering
/// outlier filter, NOT a camera calibration or a surgical accuracy guarantee.
public struct DepthObservation: Sendable {
    public let meters: Float
    public let confidence: UInt8
    public init(meters:Float,confidence:UInt8) {
        self.meters=meters
        self.confidence=confidence
    }
}

public struct DepthEstimate: Sendable {
    public let meters: Float
    public let acceptedCount: Int
    public let maxAbsoluteDeviationMeters: Float
}

public enum DepthStatistics {
    public static func estimate(_ observations:[DepthObservation],
                                minimumConfidence:UInt8=1,
                                minimumSamples:Int=4,
                                maximumDeviationMeters:Float=0.035) -> DepthEstimate? {
        guard minimumSamples > 0, maximumDeviationMeters.isFinite,
              maximumDeviationMeters > 0 else { return nil }
        let depths=observations.compactMap { sample -> Float? in
            guard sample.confidence >= minimumConfidence,
                  sample.meters.isFinite,
                  sample.meters >= 0.15 && sample.meters <= 2.5 else { return nil }
            return sample.meters
        }.sorted()
        guard depths.count >= minimumSamples else { return nil }
        let mid=depths.count/2
        let median=depths.count%2==0 ? (depths[mid-1]+depths[mid])*0.5 : depths[mid]
        let accepted=depths.filter { abs($0-median) <= maximumDeviationMeters }.sorted()
        guard accepted.count>=minimumSamples else { return nil }
        let m=accepted.count/2
        let filteredMedian=accepted.count%2==0 ? (accepted[m-1]+accepted[m])*0.5 : accepted[m]
        return DepthEstimate(meters:filteredMedian,acceptedCount:accepted.count,
                             maxAbsoluteDeviationMeters:accepted.map { abs($0-filteredMedian) }.max() ?? 0)
    }
}
