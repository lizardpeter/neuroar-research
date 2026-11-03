import Foundation

public struct SurfaceRegistrationReport: Sendable {
    public let transform: RegistrationResult
    /// Residual from *fitted* surface points, NOT independently validated TRE.
    public let fittedRMSEMeters: Double
    public let matchedPointCount: Int
    public let sampledPointCount: Int
    public let iterations: Int
    public let converged: Bool
}

public enum SurfaceRegistrationError: Error, LocalizedError {
    case insufficientCorrespondences, unstableFit, invalidInput
    public var errorDescription: String? {
        switch self {
        case .insufficientCorrespondences: "Insufficient nearby matching points. Use well-distributed landmarks and capture the visible face surface."
        case .unstableFit: "Surface refinement moved too far from the landmark alignment. Keep the landmark solution."
        case .invalidInput: "Surface samples and rigid seed must be finite and well formed."
        }
    }
}

/// Conservative point-to-point trimmed ICP refinement, *seeded by independent
/// point correspondences*. No automatic patient-to-MRI identification is claimed.
/// Both surfaces and output transforms use ARKit world METERS.
public enum TrimmedSurfaceICP {
    public static func refine(sourceMeters: [Point3], observedMeters: [Point3],
                              initial: RegistrationResult, maxDistanceMeters: Double = 0.025,
                              iterations: Int = 18, trimFraction: Double = 0.75) throws -> SurfaceRegistrationReport {
        guard !sourceMeters.isEmpty, !observedMeters.isEmpty,
              sourceMeters.count <= 250_000, observedMeters.count <= 250_000,
              sourceMeters.allSatisfy(\.allFinite), observedMeters.allSatisfy(\.allFinite),
              initial.translationMeters.allFinite, initial.quaternionWXYZ.count==4,
              initial.quaternionWXYZ.allSatisfy(\.isFinite),
              maxDistanceMeters.isFinite, (0.005...0.08).contains(maxDistanceMeters),
              (5...40).contains(iterations), (0.5...1).contains(trimFraction) else {
            throw SurfaceRegistrationError.invalidInput
        }
        // Explicit upper bound limits computational and memory cost on mobile.
        func subsample(_ points:[Point3], maxCount:Int)->[Point3] {
            if points.count<=maxCount { return points }
            let strideSize=Double(points.count)/Double(maxCount)
            return (0..<maxCount).map { points[Int(Double($0)*strideSize)] }
        }
        let source=subsample(sourceMeters,maxCount:1800)
        let observed=subsample(observedMeters,maxCount:2400)
        let gridSize=maxDistanceMeters
        struct Key: Hashable { let x:Int; let y:Int; let z:Int }
        func key(_ p:Point3)->Key {
            Key(x:Int(floor(p.x/gridSize)),y:Int(floor(p.y/gridSize)),z:Int(floor(p.z/gridSize)))
        }
        var grid:[Key:[Point3]]=[:]
        for p in observed { grid[key(p),default:[]].append(p) }
        func pairs(_ transform:RegistrationResult)->[(source:Point3,target:Point3,error:Double)] {
            var matches:[(Point3,Point3,Double)]=[]
            for p in source {
                let world=transform.transform(p)
                let cell=key(world)
                var nearest:Point3?,best=maxDistanceMeters
                for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                    for t in grid[Key(x:cell.x+dx,y:cell.y+dy,z:cell.z+dz)] ?? [] {
                        let distance=(world-t).norm
                        if distance<best { best=distance;nearest=t }
                    }
                }}}
                if let nearest { matches.append((p,nearest,best)) }
            }
            matches.sort { $0.2 < $1.2 }
            return matches
        }
        var estimate=initial
        var completed=0,converged=false
        for iteration in 0..<iterations {
            let matches=pairs(estimate)
            let take=min(matches.count,Int(Double(matches.count)*trimFraction))
            guard take >= 15 else { throw SurfaceRegistrationError.insufficientCorrespondences }
            let chosen=Array(matches.prefix(take))
            let fit=try RigidRegistration.fit(sourceMeters:chosen.map(\.source),targetMeters:chosen.map(\.target))
            // Fail closed rather than permitting large shifts from the manual seed.
            let displacement=(fit.translationMeters-initial.translationMeters).norm
            let dotQ=abs(zip(fit.quaternionWXYZ,initial.quaternionWXYZ).reduce(0.0) {$0 + $1.0*$1.1})
            let angle=2*acos(min(1,max(-1,dotQ)))
            guard displacement<=0.06,angle<=0.35 else { throw SurfaceRegistrationError.unstableFit }
            let shift=(fit.translationMeters-estimate.translationMeters).norm
            let dotStep=abs(zip(fit.quaternionWXYZ,estimate.quaternionWXYZ).reduce(0.0) {$0 + $1.0*$1.1})
            let rotationStep=2*acos(min(1,max(-1,dotStep)))
            estimate=fit
            completed=iteration+1
            if shift<0.00008 && rotationStep<0.001 { converged=true;break }
        }
        let matches=pairs(estimate)
        let take=min(matches.count,Int(Double(matches.count)*trimFraction))
        guard take>=15 else { throw SurfaceRegistrationError.insufficientCorrespondences }
        let chosen=matches.prefix(take)
        let rms=sqrt(chosen.reduce(0.0) {$0+$1.error*$1.error}/Double(take))
        return SurfaceRegistrationReport(transform:estimate,fittedRMSEMeters:rms,
                                         matchedPointCount:take,sampledPointCount:source.count,
                                         iterations:completed,converged:converged)
    }
}
