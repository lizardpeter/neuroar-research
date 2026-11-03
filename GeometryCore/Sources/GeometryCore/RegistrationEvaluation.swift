import Foundation

/// Landmark registration with an optional *external-surface* hold-out check.
/// The final correspondence is excluded from the fit when >=4 landmarks are
/// supplied. This is not intracranial target registration error and does not
/// establish safe accuracy for surgery or EVD placement.
public struct RegistrationEvaluation: Sendable {
    public let fit: RegistrationResult
    public let heldOutSurfaceResidualMeters: Double?
    public let fittedPointCount: Int
    public let hasHeldOutPoint: Bool
}

public enum LandmarkRegistrationEvaluator {
    public static func evaluate(sourceMeters:[Point3],targetMeters:[Point3]) throws -> RegistrationEvaluation {
        guard sourceMeters.count == targetMeters.count else { throw RegistrationError.unequalCounts }
        guard sourceMeters.count >= 3 else { throw RegistrationError.insufficientPoints }
        guard (sourceMeters + targetMeters).allSatisfy(\.allFinite) else { throw RegistrationError.nonFinite }
        let holdout = sourceMeters.count >= 4
        let fitCount = holdout ? sourceMeters.count-1 : sourceMeters.count
        let fit=try RigidRegistration.fit(sourceMeters:Array(sourceMeters.prefix(fitCount)),
                                          targetMeters:Array(targetMeters.prefix(fitCount)))
        let heldOut = holdout
            ? (fit.transform(sourceMeters[fitCount]) - targetMeters[fitCount]).norm
            : nil
        return RegistrationEvaluation(fit:fit,heldOutSurfaceResidualMeters:heldOut,
                                      fittedPointCount:fitCount,hasHeldOutPoint:holdout)
    }
}
