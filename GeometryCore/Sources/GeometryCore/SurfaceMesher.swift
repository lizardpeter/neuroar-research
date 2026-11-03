import Foundation

/// Coarse triangle-soup iso-surface for research visualization, not diagnostic segmentation.
/// All vertices remain in the volume's canonical patient-relative **millimeter** frame.
/// The mesher deliberately samples a reduced grid and imposes a triangle budget.
public struct PreviewSurface: Sendable {
    public let verticesMm: [Point3]
    public let samplingStepVoxels: Int
    public let truncated: Bool
    public var triangleCount: Int { verticesMm.count / 3 }
}

public enum PreviewSurfaceMesher {
    /// Extract an approximate iso-surface using marching tetrahedra.
    /// `threshold` is a scalar intensity/label cutoff, NOT an anatomical classifier.
    /// A result with `truncated == true` is incomplete and should not be interpreted as a surface.
    public static func extract(volume: VoxelVolume, threshold: Float,
                               maxCells: Int = 120_000,
                               maxTriangles: Int = 70_000) -> PreviewSurface {
        let dim = volume.dimensions
        guard threshold.isFinite, maxCells > 0, maxTriangles > 0 else {
            return PreviewSurface(verticesMm: [], samplingStepVoxels: 1, truncated: false)
        }
        let cells = dim.map { max(1, $0 - 1) }
        var step = 1
        while ((cells[0] + step - 1) / step) * ((cells[1] + step - 1) / step) *
              ((cells[2] + step - 1) / step) > maxCells { step += 1 }

        // Cube-corner order: 0=000 1=100 2=110 3=010 4=001 5=101 6=111 7=011
        let offsets: [(Int,Int,Int)] = [
            (0,0,0),(1,0,0),(1,1,0),(0,1,0),
            (0,0,1),(1,0,1),(1,1,1),(0,1,1)
        ]
        // Six tetrahedra share cube diagonal (0,6).
        let tets: [[Int]] = [[0,1,2,6],[0,2,3,6],[0,3,7,6],
                             [0,7,4,6],[0,4,5,6],[0,5,1,6]]
        var result: [Point3] = []
        result.reserveCapacity(min(maxTriangles * 3, 90_000))
        var truncated = false

        func interpolate(_ a: Int, _ b: Int, positions: [Point3], values: [Float]) -> Point3 {
            let va = values[a], vb = values[b]
            let delta = vb - va
            let t = abs(delta) < 1e-8 ? 0.5 : min(1, max(0, Double((threshold - va) / delta)))
            return positions[a] + (positions[b] - positions[a]) * t
        }
        func append(_ a: Point3, _ b: Point3, _ c: Point3) -> Bool {
            guard result.count / 3 < maxTriangles else { truncated = true; return false }
            // Suppress degenerate triangles generated at exact threshold vertices.
            let u = b - a, v = c - a
            let area2 = Point3(u.y*v.z-u.z*v.y, u.z*v.x-u.x*v.z, u.x*v.y-u.y*v.x).norm
            if area2 > 1e-9 && a.allFinite && b.allFinite && c.allFinite {
                result.append(contentsOf: [a,b,c])
            }
            return true
        }
        var k=0
        while k<dim[2]-1 && !truncated {
            var j=0
            while j<dim[1]-1 && !truncated {
                var i=0
                while i<dim[0]-1 && !truncated {
                    let dx=min(step,dim[0]-1-i),dy=min(step,dim[1]-1-j),dz=min(step,dim[2]-1-k)
                    var positions:[Point3]=[];var values:[Float]=[]
                    positions.reserveCapacity(8);values.reserveCapacity(8)
                    for (ox,oy,oz) in offsets {
                        let x=i+ox*dx,y=j+oy*dy,z=k+oz*dz
                        positions.append(volume.affine.point(i:Double(x),j:Double(y),k:Double(z)))
                        values.append(volume.value(i:x,j:y,k:z) ?? 0)
                    }
                    for tet in tets {
                        let inside=tet.filter { values[$0].isFinite && values[$0] >= threshold }
                        if inside.isEmpty || inside.count==4 { continue }
                        let outside=tet.filter { !inside.contains($0) }
                        if inside.count==1 {
                            let a=inside[0]
                            if !append(interpolate(a,outside[0],positions:positions,values:values),
                                       interpolate(a,outside[1],positions:positions,values:values),
                                       interpolate(a,outside[2],positions:positions,values:values)) { break }
                        } else if inside.count==3 {
                            let a=outside[0]
                            if !append(interpolate(a,inside[0],positions:positions,values:values),
                                       interpolate(a,inside[2],positions:positions,values:values),
                                       interpolate(a,inside[1],positions:positions,values:values)) { break }
                        } else {
                            let a=interpolate(inside[0],outside[0],positions:positions,values:values)
                            let b=interpolate(inside[0],outside[1],positions:positions,values:values)
                            let c=interpolate(inside[1],outside[0],positions:positions,values:values)
                            let d=interpolate(inside[1],outside[1],positions:positions,values:values)
                            if !append(a,b,c) || !append(b,d,c) { break }
                        }
                    }
                    i+=step
                }
                j+=step
            }
            k+=step
        }
        return PreviewSurface(verticesMm:result,samplingStepVoxels:step,truncated:truncated)
    }
}
