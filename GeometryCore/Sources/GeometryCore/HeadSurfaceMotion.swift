import Foundation

/// Short-lived markerless head-motion estimates from consecutive LiDAR clouds.
/// These *are not* anatomical registration, subject identification, or clinical
/// tracking. The caller must already have a separately established MRI pose.
public struct HeadSurfaceMotionReport: Sendable {
    /// Previous world-space head-cloud coordinates -> current world coordinates.
    public let delta: RegistrationResult
    /// Correspondence-fitting error, not physical target registration error.
    public let fittedRMSEMeters: Double
    public let matchedCount: Int
    public let referenceCount: Int
    public let translationMeters: Double
    public let rotationRadians: Double
}

public enum HeadSurfaceMotionError: Error, LocalizedError {
    case insufficientSurface, weakGeometry, inconsistentMotion
    public var errorDescription: String? {
        switch self {
        case .insufficientSurface: "Head surface is not sufficiently visible for tracking."
        case .weakGeometry: "LiDAR head surface has insufficient three-dimensional structure."
        case .inconsistentMotion: "Head-surface tracking is ambiguous or moved too far."
        }
    }
}

public enum HeadSurfaceMotion {
    /// Seedless *incremental* point-cloud tracking: only for short periods after
    /// a natural-feature match, over a small inter-frame displacement.
    /// Limits are experimental quality gates, never millimeter-accuracy claims.
    public static func estimate(previousMeters: [Point3], currentMeters: [Point3]) throws -> HeadSurfaceMotionReport {
        guard (80...2400).contains(previousMeters.count), (80...2400).contains(currentMeters.count),
              previousMeters.allSatisfy(\.allFinite), currentMeters.allSatisfy(\.allFinite) else {
            throw HeadSurfaceMotionError.insufficientSurface
        }
        guard hasVolume(previousMeters), hasVolume(currentMeters) else {
            throw HeadSurfaceMotionError.weakGeometry
        }
        let identity = RegistrationResult(quaternionWXYZ: [1, 0, 0, 0],
                                          translationMeters: Point3(0, 0, 0),
                                          landmarkRMSEmeters: 0, maxLandmarkResidualMeters: 0, count: 0)
        let estimate: SurfaceRegistrationReport
        do {
            estimate = try TrimmedSurfaceICP.refine(sourceMeters: previousMeters,
                                                    observedMeters: currentMeters,
                                                    initial: identity,
                                                    maxDistanceMeters: 0.030,
                                                    iterations: 14,
                                                    trimFraction: 0.72)
        } catch {
            throw HeadSurfaceMotionError.inconsistentMotion
        }
        let q = estimate.transform.quaternionWXYZ
        let angle = 2 * acos(min(1, max(-1, abs(q[0]))))
        let displacement = estimate.transform.translationMeters.norm
        // Avoid success based on a tiny accidental patch of nearby background.
        // ICP is not an independent validation of head identity or registration.
        let minMatches = max(55, Int(Double(min(previousMeters.count, 1800)) * 0.32))
        guard estimate.matchedPointCount >= minMatches,
              estimate.fittedRMSEMeters.isFinite,
              estimate.fittedRMSEMeters < 0.009,
              displacement < 0.035,
              angle < 0.23 else {
            throw HeadSurfaceMotionError.inconsistentMotion
        }
        return HeadSurfaceMotionReport(delta: estimate.transform,
                                       fittedRMSEMeters: estimate.fittedRMSEMeters,
                                       matchedCount: estimate.matchedPointCount,
                                       referenceCount: min(previousMeters.count, 1800),
                                       translationMeters: displacement,
                                       rotationRadians: angle)
    }

    private static func hasVolume(_ cloud: [Point3]) -> Bool {
        guard let first = cloud.first else { return false }
        var lo = first, hi = first
        for point in cloud.dropFirst() {
            for axis in 0..<3 {
                lo[axis] = min(lo[axis], point[axis]); hi[axis] = max(hi[axis], point[axis])
            }
        }
        let spans = [hi.x-lo.x, hi.y-lo.y, hi.z-lo.z].sorted()
        // A flat wall, hair fragment, or slender ray is not adequate 3D shape.
        return spans[0] > 0.012 && spans[1] > 0.060 && spans[2] > 0.060
    }
}
