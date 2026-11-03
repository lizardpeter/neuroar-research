import Foundation
import GeometryCore

/// C ABI function exported by RustCore; linked into the native iOS target.
@_silgen_name("neuroar_distance_mm")
private func neuroar_distance_mm(_ ax: Double, _ ay: Double, _ az: Double,
                                 _ bx: Double, _ by: Double, _ bz: Double) -> Double

/// A verified, computationally useful bridge; geometry is expressed in MRI mm.
/// More compute kernels will be migrated once CI verifies device and simulator.
enum RustBridge {
    static func pathLengthMm(_ trajectory: StudyTrajectory) -> Double {
        let a=trajectory.entryMm, b=trajectory.targetMm
        return neuroar_distance_mm(a.x,a.y,a.z,b.x,b.y,b.z)
    }
}
