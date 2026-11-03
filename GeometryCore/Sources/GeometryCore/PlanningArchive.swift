import Foundation

/// Portable research-only plan representation. Deliberately does not store image pixels,
/// patient names, clinical identifiers, or any registration to a real-world head.
/// The image fingerprint is a non-cryptographic *matching check*, not anonymization.
public struct VoxelGridIdentity: Codable, Sendable, Equatable {
    public let dimensions: [Int]
    public let originMm: Point3
    public let iMm: Point3
    public let jMm: Point3
    public let kMm: Point3
    public let fingerprint: String

    public init(volume: VoxelVolume) {
        dimensions = volume.dimensions
        originMm = volume.affine.originMm
        iMm = volume.affine.iMm
        jMm = volume.affine.jMm
        kMm = volume.affine.kMm
        // 64-bit FNV-1a over geometry and ALL voxel bit-patterns. This detects
        // ordinary accidental mismatches, but is NOT a secure patient-data hash.
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ word: UInt64) {
            var bits = word
            for _ in 0..<8 {
                hash = (hash ^ (bits & 0xff)) &* 1_099_511_628_211
                bits >>= 8
            }
        }
        for dimension in dimensions { mix(UInt64(dimension)) }
        for p in [originMm,iMm,jMm,kMm] {
            mix(p.x.bitPattern); mix(p.y.bitPattern); mix(p.z.bitPattern)
        }
        for v in volume.voxels { mix(UInt64(v.bitPattern)) }
        fingerprint = String(hash, radix: 16, uppercase: false)
    }

    public func matches(_ volume: VoxelVolume) -> Bool {
        self == VoxelGridIdentity(volume:volume)
    }
}

public enum PlanningArchiveError: Error, LocalizedError, Sendable {
    case unsupportedVersion
    case differentImage
    case invalidCoordinates
    case invalidGeometry
    case excessiveEntries

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Unsupported planning archive format or coordinate system."
        case .differentImage: "This plan belongs to different image pixels or a different physical voxel grid. It was not imported."
        case .invalidCoordinates: "Plan points must be finite and within the selected MRI volume."
        case .invalidGeometry: "Plan contains an invalid or zero-length line, duplicate identifiers, or an invalid depth."
        case .excessiveEntries: "Too many annotations or candidate paths in the plan."
        }
    }
}

public struct PlanningArchive: Codable, Sendable {
    public static let formatVersion = 1
    public static let canonicalFrame = "R+S+A_mm"

    public let version: Int
    public let coordinateFrame: String
    public let image: VoxelGridIdentity
    public let cursorMm: Point3
    public let entryMm: Point3
    public let targetMm: Point3
    public let displayedDepthMm: Double
    public let landmarks: [StudyLandmark]
    public let candidates: [StudyTrajectory]

    public init(volume: VoxelVolume, cursorMm: Point3, entryMm: Point3,
                targetMm: Point3, displayedDepthMm: Double,
                landmarks: [StudyLandmark], candidates: [StudyTrajectory]) throws {
        version = Self.formatVersion
        coordinateFrame = Self.canonicalFrame
        image = VoxelGridIdentity(volume:volume)
        self.cursorMm = cursorMm
        self.entryMm = entryMm
        self.targetMm = targetMm
        self.displayedDepthMm = displayedDepthMm
        self.landmarks = landmarks
        self.candidates = candidates
        try validate(for:volume)
    }

    public func validate(for volume: VoxelVolume) throws {
        guard version == Self.formatVersion, coordinateFrame == Self.canonicalFrame else {
            throw PlanningArchiveError.unsupportedVersion
        }
        guard image.matches(volume) else { throw PlanningArchiveError.differentImage }
        guard landmarks.count <= 64, candidates.count <= 256 else {
            throw PlanningArchiveError.excessiveEntries
        }
        let allPoints = [cursorMm,entryMm,targetMm]
            + landmarks.map(\.pointMm)
            + candidates.flatMap { [$0.entryMm, $0.targetMm] }
        guard allPoints.allSatisfy({ $0.allFinite && volume.affine.index(of:$0).allFinite
                && volume.nearest(at:$0) != nil }) else {
            throw PlanningArchiveError.invalidCoordinates
        }
        let pathLength = (targetMm-entryMm).norm
        guard pathLength.isFinite, pathLength > 1e-6,
              displayedDepthMm.isFinite, displayedDepthMm >= 0,
              displayedDepthMm <= pathLength + 1e-7,
              Set(landmarks.map(\.id)).count == landmarks.count,
              Set(candidates.map(\.id)).count == candidates.count,
              landmarks.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.name.count <= 100 }),
              candidates.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.name.count <= 100
                  && $0.lengthMm.isFinite && $0.lengthMm > 1e-6 }) else {
            throw PlanningArchiveError.invalidGeometry
        }
    }
}

/// A sampled research-only intensity profile along a manually drawn MRI line.
/// NOT a vascular clearance calculation or an EVD path recommendation.
public struct PathSample: Sendable {
    public let distanceMm: Double
    public let intensity: Float?
    public let insideROI: Bool
}

public enum PathSampler {
    public static func sample(_ path: StudyTrajectory, volume: VoxelVolume,
                              mask: VoxelVolume? = nil, spacingMm: Double = 1) -> [PathSample] {
        guard path.entryMm.allFinite, path.targetMm.allFinite,
              path.lengthMm.isFinite, path.lengthMm > 0,
              spacingMm.isFinite, spacingMm > 0 else { return [] }
        let n = min(10_000, max(1, Int(ceil(path.lengthMm / max(spacingMm,0.01)))))
        return (0...n).map { i in
            let distance = path.lengthMm * Double(i) / Double(n)
            let point = path.atDepth(distance)
            return PathSample(distanceMm:distance,
                              intensity:volume.trilinear(at:point),
                              insideROI:(mask?.nearest(at:point) ?? 0) > 0.5)
        }
    }
}
