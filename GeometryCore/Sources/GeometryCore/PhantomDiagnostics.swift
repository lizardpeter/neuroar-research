import Foundation

/// Numerical statistics from a SINGLE-frame LiDAR cloud. No coordinates or
/// camera images are retained. Spatial spread is not sensor *accuracy*.
public struct PhantomDepthStatistics: Codable, Sendable {
    public let sampleCount: Int
    public let spatialSpreadMm: Double
    public let medianRadiusMm: Double
    public let rangeMm: Double

    public static func analyze(_ pointsMeters:[Point3]) -> Self? {
        guard pointsMeters.count >= 10,pointsMeters.count <= 10_000,
              pointsMeters.allSatisfy(\.allFinite) else { return nil }
        let centroid=pointsMeters.reduce(Point3(0,0,0),+)*(1/Double(pointsMeters.count))
        let d=pointsMeters.map { ($0-centroid).norm*1000 }.sorted()
        let mean=d.reduce(0,+)/Double(d.count)
        let stddev=sqrt(d.reduce(0.0){ $0+($1-mean)*($1-mean) }/Double(d.count))
        return Self(sampleCount:pointsMeters.count,spatialSpreadMm:stddev,
                    medianRadiusMm:d[d.count/2],rangeMm:(d.last ?? 0)-(d.first ?? 0))
    }
}
