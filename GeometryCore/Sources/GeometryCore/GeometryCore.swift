import Foundation

/// Unit-bearing data transfer object. Study points are in millimeters.
public struct Point3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }
    public subscript(_ i: Int) -> Double {
        get { switch i { case 0: x; case 1: y; default: z } }
        set { switch i { case 0: x = newValue; case 1: y = newValue; default: z = newValue } }
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
    public static func - (lhs: Self, rhs: Self) -> Self {
        .init(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }
    public static func * (lhs: Self, rhs: Double) -> Self {
        .init(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }
    public var norm: Double { sqrt(x*x + y*y + z*z) }
    public var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

/// World points, translation, and residuals are in meters; rotation is a unit quaternion.
public struct RegistrationResult: Sendable {
    public let quaternionWXYZ: [Double]
    public let translationMeters: Point3
    public let landmarkRMSEmeters: Double
    public let maxLandmarkResidualMeters: Double
    public let count: Int

    public func transform(_ p: Point3) -> Point3 {
        let q = quaternionWXYZ
        let v = Point3(q[1], q[2], q[3])
        let t = cross(v, p) * 2.0
        return p + t * q[0] + cross(v, t) + translationMeters
    }
}

public enum RegistrationError: Error, LocalizedError {
    case unequalCounts, insufficientPoints, degenerateConfiguration, nonFinite
    public var errorDescription: String? {
        switch self {
        case .unequalCounts: "MRI and camera landmarks must have matching counts."
        case .insufficientPoints: "At least three matching landmarks are required."
        case .degenerateConfiguration: "Landmarks are collinear or too close together."
        case .nonFinite: "Invalid landmark coordinate."
        }
    }
}

private func dot(_ a: Point3, _ b: Point3) -> Double { a.x*b.x + a.y*b.y + a.z*b.z }
private func cross(_ a: Point3, _ b: Point3) -> Point3 {
    .init(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x)
}

public enum RigidRegistration {
    /// Horn quaternion least-squares fit. No scaling, no reflection, no deformation.
    /// MRI coordinates must first be converted from mm to meters; physical points are meters.
    public static func fit(sourceMeters: [Point3], targetMeters: [Point3]) throws -> RegistrationResult {
        guard sourceMeters.count == targetMeters.count else { throw RegistrationError.unequalCounts }
        guard sourceMeters.count >= 3 else { throw RegistrationError.insufficientPoints }
        guard (sourceMeters + targetMeters).allSatisfy(\.allFinite) else { throw RegistrationError.nonFinite }
        let n = sourceMeters.count
        let aMean = sourceMeters.reduce(Point3(0,0,0), +) * (1.0/Double(n))
        let bMean = targetMeters.reduce(Point3(0,0,0), +) * (1.0/Double(n))
        let a = sourceMeters.map { $0-aMean }
        let b = targetMeters.map { $0-bMean }
        // Reject near-collinear inputs: require at least one triangle of meaningful area.
        var maxCross: Double = 0
        for i in 1..<n { for j in (i+1)..<n {
            maxCross = max(maxCross, cross(a[i]-a[0], a[j]-a[0]).norm)
        }}
        guard maxCross > 1.0e-6 else { throw RegistrationError.degenerateConfiguration }
        var s = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for k in 0..<n { for i in 0..<3 { for j in 0..<3 { s[i][j] += a[k][i]*b[k][j] } } }
        let xx=s[0][0], xy=s[0][1], xz=s[0][2]
        let yx=s[1][0], yy=s[1][1], yz=s[1][2]
        let zx=s[2][0], zy=s[2][1], zz=s[2][2]
        var m: [[Double]] = [
            [xx+yy+zz, yz-zy, zx-xz, xy-yx],
            [yz-zy, xx-yy-zz, xy+yx, zx+xz],
            [zx-xz, xy+yx, -xx+yy-zz, yz+zy],
            [xy-yx, zx+xz, yz+zy, -xx-yy+zz]
        ]
        // Symmetric Jacobi eigen-decomposition (not power iteration: the largest
        // algebraic eigenvalue is required, not the largest-magnitude eigenvalue).
        var eigenvectors: [[Double]] = (0..<4).map { i in (0..<4).map { j in i == j ? 1.0 : 0.0 } }
        for _ in 0..<80 {
            var p=0, q=1, largest=0.0
            for i in 0..<4 { for j in (i+1)..<4 {
                if abs(m[i][j]) > largest { largest=abs(m[i][j]); p=i; q=j }
            }}
            if largest < 1.0e-14 { break }
            let tau = (m[q][q]-m[p][p])/(2*m[p][q])
            let t = (tau >= 0 ? 1.0 : -1.0)/(abs(tau)+sqrt(1+tau*tau))
            let c = 1/sqrt(1+t*t), sn=t*c
            let app=m[p][p], aqq=m[q][q], apq=m[p][q]
            m[p][p]=app-t*apq; m[q][q]=aqq+t*apq
            m[p][q]=0; m[q][p]=0
            for i in 0..<4 where i != p && i != q {
                let ip=m[i][p], iq=m[i][q]
                m[i][p]=c*ip-sn*iq; m[p][i]=m[i][p]
                m[i][q]=sn*ip+c*iq; m[q][i]=m[i][q]
            }
            for i in 0..<4 {
                let ip=eigenvectors[i][p], iq=eigenvectors[i][q]
                eigenvectors[i][p]=c*ip-sn*iq
                eigenvectors[i][q]=sn*ip+c*iq
            }
        }
        let best = (0..<4).max { m[$0][$0] < m[$1][$1] }!
        var q=(0..<4).map { eigenvectors[$0][best] }
        let qNorm=sqrt(q.reduce(0.0) { $0+$1*$1 })
        q=q.map { $0/qNorm }
        if q[0] < 0 { q=q.map { -$0 } }
        let temp=RegistrationResult(quaternionWXYZ:q, translationMeters:.init(0,0,0), landmarkRMSEmeters:0, maxLandmarkResidualMeters:0, count:n)
        let t=bMean-temp.transform(aMean)
        let r=RegistrationResult(quaternionWXYZ:q, translationMeters:t, landmarkRMSEmeters:0, maxLandmarkResidualMeters:0, count:n)
        let residuals=zip(sourceMeters,targetMeters).map { (r.transform($0)-$1).norm }
        return RegistrationResult(quaternionWXYZ:q, translationMeters:t,
                                  landmarkRMSEmeters:sqrt(residuals.reduce(0) {$0+$1*$1}/Double(n)),
                                  maxLandmarkResidualMeters:residuals.max() ?? 0, count:n)
    }
}

public struct StudyLandmark: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let pointMm: Point3
}

public struct StudyTrajectory: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public var entryMm: Point3
    public var targetMm: Point3
    public var lengthMm: Double { (targetMm-entryMm).norm }
    public func atDepth(_ depthMm: Double) -> Point3 {
        let d = max(0, min(depthMm, lengthMm))
        if lengthMm < 1e-8 { return entryMm }
        return entryMm + (targetMm-entryMm) * (d/lengthMm)
    }
}

public struct Study: Codable, Sendable {
    public let id: String
    public let title: String
    public let isSynthetic: Bool
    public let landmarks: [StudyLandmark]
    public var trajectories: [StudyTrajectory]
    /// Right(+X), superior(+Y), anterior(+Z), in millimeters.
    public static let synthetic = Study(
        id: "synthetic-education-only", title: "Synthetic anatomy (demo)", isSynthetic: true,
        landmarks: [
            .init(id:"nose",name:"Nose bridge",pointMm:.init(0,5,90)),
            .init(id:"leftBrow",name:"Left brow",pointMm:.init(-34,12,75)),
            .init(id:"rightBrow",name:"Right brow",pointMm:.init(34,12,75)),
            .init(id:"chin",name:"Chin",pointMm:.init(0,-65,55))
        ],
        trajectories: [.init(id:"sample",name:"Synthetic path (NOT EVD guidance)",
                             entryMm:.init(35,65,30),targetMm:.init(5,0,4))]
    )
}
