import Foundation

/// Conservative visibility gate for an *unvalidated* research AR overlay.
/// A successful ICP or landmark fit is never proof of surgical accuracy.
public enum OverlayTrackingSource: Equatable, Sendable {
    case hidden
    case naturalFace
    case shortTermSurface
}

public enum OverlayTrackingGate {
    /// Ages are measured from the current ARFrame timestamp, not wall-clock
    /// time, so a delayed Vision callback cannot re-enable a stale overlay.
    /// Thresholds are software freshness guards, not medical tolerances.
    public static func source(cameraNormal: Bool, headBound: Bool, hasPose: Bool,
                              faceVisible: Bool, surfaceTracking: Bool,
                              secondsSinceFace: Double?, secondsSinceMotion: Double?) -> OverlayTrackingSource {
        guard cameraNormal, headBound, hasPose else { return .hidden }
        if faceVisible, let age = secondsSinceFace,
           age.isFinite, age >= 0, age <= 0.40 {
            return .naturalFace
        }
        if surfaceTracking, let faceAge = secondsSinceFace,
           let motionAge = secondsSinceMotion,
           faceAge.isFinite, motionAge.isFinite,
           faceAge >= 0, faceAge <= 1.8,
           motionAge >= 0, motionAge <= 0.40 {
            return .shortTermSurface
        }
        return .hidden
    }
}
