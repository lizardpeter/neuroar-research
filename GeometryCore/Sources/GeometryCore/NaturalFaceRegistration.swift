import Foundation

/// Camera-derived natural facial features. Never attach printed markers or
/// infer an MRI identity merely because a face is visible.
public enum NaturalFaceFeature: String, CaseIterable, Codable, Sendable {
    case leftEyeCenter, rightEyeCenter, noseTip, mouthCenter

    /// Require an explicitly labelled *anatomical correspondence* in the MRI.
    /// UUIDs from the planner are fine: matching is by the displayed label.
    public static func fromMRIName(_ name: String) -> Self? {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "lefteyecenter": return .leftEyeCenter
        case "righteyecenter": return .rightEyeCenter
        case "nosetip": return .noseTip
        case "mouthcenter": return .mouthCenter
        default: return nil
        }
    }
}

public struct NaturalFacePoint: Sendable {
    public let feature: NaturalFaceFeature
    public let worldMeters: Point3
    public init(feature: NaturalFaceFeature, worldMeters: Point3) {
        self.feature = feature
        self.worldMeters = worldMeters
    }
}

public struct NaturalFaceFit: Sendable {
    public let transform: RegistrationResult
    /// Training residual only, not target registration error.
    public let rmsMeters: Double
    public let maxResidualMeters: Double
    public let matchedFeatures: Int
}

public enum NaturalFaceError: Error, LocalizedError {
    case missingCorrespondences, duplicateFeatures, implausibleGeometry, excessiveResidual, excessiveMotion
    public var errorDescription: String? {
        switch self {
        case .missingCorrespondences: "Requires the same three or four natural facial features on the MRI and camera."
        case .duplicateFeatures: "Duplicate facial feature labels were supplied."
        case .implausibleGeometry: "Facial features are too close, non-finite, or geometrically unstable."
        case .excessiveResidual: "Natural feature alignment residual exceeds the research guard. No overlay is shown."
        case .excessiveMotion: "The measured head jump is implausibly large; reacquire registration."
        }
    }
}

/// Geometry-only component: can be unit-tested without ARKit or an iPhone.
/// These demonstration guards are NOT clinical acceptance criteria.
public enum NaturalFaceRegistration {
    public static func mriFeatures(_ landmarks: [StudyLandmark]) throws -> [NaturalFacePoint] {
        var result = [NaturalFacePoint]()
        for landmark in landmarks {
            guard let feature = NaturalFaceFeature.fromMRIName(landmark.name) ?? NaturalFaceFeature.fromMRIName(landmark.id) else { continue }
            guard !result.contains(where: { $0.feature == feature }) else { throw NaturalFaceError.duplicateFeatures }
            result.append(.init(feature: feature, worldMeters: landmark.pointMm * 0.001))
        }
        return result
    }

    public static func fit(mri: [NaturalFacePoint], camera: [NaturalFacePoint],
                           maximumRMSMeters: Double = 0.020) throws -> NaturalFaceFit {
        guard maximumRMSMeters.isFinite, (0.001...0.05).contains(maximumRMSMeters) else {
            throw NaturalFaceError.implausibleGeometry
        }
        let (source, target) = try paired(mri, camera)
        let fit: RegistrationResult
        do { fit = try RigidRegistration.fit(sourceMeters: source, targetMeters: target) }
        catch { throw NaturalFaceError.implausibleGeometry }
        guard fit.landmarkRMSEmeters <= maximumRMSMeters,
              fit.maxLandmarkResidualMeters <= maximumRMSMeters * 1.7 else {
            throw NaturalFaceError.excessiveResidual
        }
        return .init(transform: fit, rmsMeters: fit.landmarkRMSEmeters,
                     maxResidualMeters: fit.maxLandmarkResidualMeters, matchedFeatures: source.count)
    }

    public static func motion(reference: [NaturalFacePoint], observed: [NaturalFacePoint]) throws -> NaturalFaceFit {
        let report = try fit(mri: reference, camera: observed, maximumRMSMeters: 0.020)
        let t = report.transform.translationMeters
        // Large jumps often mean a different face was detected, or bad depth.
        guard t.norm < 0.30 else { throw NaturalFaceError.excessiveMotion }
        let q = report.transform.quaternionWXYZ
        let angle = 2 * acos(min(1, max(-1, abs(q[0]))))
        guard angle < 0.85 else { throw NaturalFaceError.excessiveMotion }
        return report
    }

    private static func paired(_ a: [NaturalFacePoint], _ b: [NaturalFacePoint]) throws -> ([Point3], [Point3]) {
        guard Set(a.map(\.feature)).count == a.count,
              Set(b.map(\.feature)).count == b.count else { throw NaturalFaceError.duplicateFeatures }
        let second = Dictionary(uniqueKeysWithValues: b.map { ($0.feature, $0.worldMeters) })
        let pairs = a.compactMap { item -> (Point3, Point3)? in
            guard let found = second[item.feature] else { return nil }
            return (item.worldMeters, found)
        }
        guard pairs.count >= 3 else { throw NaturalFaceError.missingCorrespondences }
        let source = pairs.map { $0.0 }, target = pairs.map { $0.1 }
        guard (source + target).allSatisfy(\.allFinite) else { throw NaturalFaceError.implausibleGeometry }
        // Face points on a single shallow patch can have weak 3-D conditioning;
        // enforce a minimal baseline and meaningful triangle area.
        for points in [source, target] {
            var baseline = 0.0
            for i in points.indices {
                for j in points.indices where j > i {
                    baseline = max(baseline, (points[i] - points[j]).norm)
                }
            }
            guard baseline > 0.035 else { throw NaturalFaceError.implausibleGeometry }
        }
        return (source, target)
    }
}
