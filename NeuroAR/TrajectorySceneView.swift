import SwiftUI
import SceneKit
import CoreGraphics
import GeometryCore
import simd

/// Three true MRI section textures in physical coordinates, optional coarse
/// threshold / supplied-ROI iso-surfaces, and a geometric research trajectory.
/// This is an offline visualization, NEVER a navigation overlay or segmentation.
struct TrajectorySceneView: UIViewRepresentable {
    let volume: VoxelVolume
    let revision: Int
    let maskRevision: Int
    let mask: VoxelVolume?
    let cursorMm: Point3
    let window: ClosedRange<Float>
    let tissueSurface: PreviewSurface?
    let maskSurface: PreviewSurface?
    let showSlices: Bool
    let showTissue: Bool
    let showMask: Bool
    let entryMm: Point3
    let targetMm: Point3
    let tipMm: Point3

    final class Coordinator {
        var sliceCacheKey: String = ""
        var sliceCache: [SCNNode] = []
        var lastVolumeRevision: Int = -1
        var lastBoundsCenter = Point3(0,0,0)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context:Context) -> SCNView {
        let view=SCNView(frame:.zero)
        let scene=SCNScene()
        view.scene=scene
        view.backgroundColor=UIColor(red:0.035,green:0.07,blue:0.10,alpha:1)
        view.allowsCameraControl=true
        view.autoenablesDefaultLighting=true
        view.antialiasingMode = .multisampling4X
        let cam=SCNNode()
        cam.name="orbitCamera"
        cam.camera=SCNCamera()
        cam.camera?.zNear=0.001
        cam.camera?.zFar=20
        scene.rootNode.addChildNode(cam)
        view.pointOfView=cam
        updateUIView(view,context:context)
        return view
    }

    func updateUIView(_ uiView:SCNView,context:Context) {
        guard let scene=uiView.scene else { return }
        let coordinator=context.coordinator
        let bounds=volume.bounds
        let center=bounds.center
        if coordinator.lastVolumeRevision != revision {
            coordinator.lastVolumeRevision=revision
            coordinator.lastBoundsCenter=center
            coordinator.sliceCacheKey=""
            coordinator.sliceCache=[]
            let span=max(bounds.maximum.x-bounds.minimum.x,
                         bounds.maximum.y-bounds.minimum.y,
                         bounds.maximum.z-bounds.minimum.z)/1000
            if let cam=uiView.pointOfView {
                cam.position=SCNVector3(Float(span*0.8),Float(span*0.65),Float(span*1.7))
                cam.look(at:SCNVector3(0,0,0))
            }
        }
        scene.rootNode.childNode(withName:"study",recursively:false)?.removeFromParentNode()
        let root=SCNNode()
        root.name="study"
        scene.rootNode.addChildNode(root)
        func m(_ p:Point3)->SCNVector3 {
            SCNVector3(Float((p.x-center.x)/1000),Float((p.y-center.y)/1000),
                       Float((p.z-center.z)/1000))
        }
        let lo=m(bounds.minimum),hi=m(bounds.maximum)
        let x0=lo.x,x1=hi.x,y0=lo.y,y1=hi.y,z0=lo.z,z1=hi.z
        let corners:[SCNVector3] = [
            SCNVector3(x0,y0,z0),SCNVector3(x1,y0,z0),
            SCNVector3(x0,y1,z0),SCNVector3(x1,y1,z0),
            SCNVector3(x0,y0,z1),SCNVector3(x1,y0,z1),
            SCNVector3(x0,y1,z1),SCNVector3(x1,y1,z1)
        ]
        let edges=[(0,1),(0,2),(0,4),(1,3),(1,5),(2,3),(2,6),(3,7),(4,5),(4,6),(5,7),(6,7)]
        for (a,b) in edges {
            root.addChildNode(cylinder(from:corners[a],to:corners[b],radius:0.00045,
                                       color:UIColor.systemTeal.withAlphaComponent(0.65)))
        }

        if showSlices {
            let key="\(revision)/\(maskRevision)/\(cursorMm.x)/\(cursorMm.y)/\(cursorMm.z)/\(window.lowerBound)/\(window.upperBound)/\(mask == nil)"
            if coordinator.sliceCacheKey != key {
                coordinator.sliceCacheKey=key
                coordinator.sliceCache=ImagingPlane.allCases.compactMap { plane in
                    makeSlice(plane:plane,center:center)
                }
            }
            for slice in coordinator.sliceCache {
                slice.removeFromParentNode()
                root.addChildNode(slice)
            }
        }
        if showTissue, let tissueSurface, !tissueSurface.verticesMm.isEmpty {
            root.addChildNode(surfaceNode(tissueSurface,center:center,
                                          color:UIColor.systemGray.withAlphaComponent(0.33)))
        }
        if showMask, let maskSurface, !maskSurface.verticesMm.isEmpty {
            root.addChildNode(surfaceNode(maskSurface,center:center,
                                          color:UIColor.systemCyan.withAlphaComponent(0.48)))
        }
        let a=m(entryMm),b=m(targetMm),tip=m(tipMm)
        root.addChildNode(cylinder(from:a,to:b,radius:0.0009,color:.lightGray))
        root.addChildNode(cylinder(from:a,to:tip,radius:0.002,color:.systemYellow))
        root.addChildNode(sphere(at:a,radius:0.005,color:.systemOrange))
        root.addChildNode(sphere(at:b,radius:0.005,color:.systemPurple))
        root.addChildNode(sphere(at:tip,radius:0.004,color:.systemYellow))
    }

    private func makeSlice(plane:ImagingPlane,center:Point3) -> SCNNode? {
        let raster=SliceRenderer.render(volume:volume,mask:mask,plane:plane,
                                        cursor:cursorMm,window:window,width:192,height:192)
        let data=Data(raster.rgba) as CFData
        guard let provider=CGDataProvider(data:data),
              let image=CGImage(width:raster.width,height:raster.height,
                                bitsPerComponent:8,bitsPerPixel:32,
                                bytesPerRow:raster.width*4,space:CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {
            return nil
        }
        let frame=raster.frame
        let coords=[(0.0,0.0),(1.0,0.0),(0.0,1.0),(1.0,1.0)]
        let vertices:[SCNVector3]=coords.map { u,v in
            let pt=frame.world(u:u,v:v)
            return SCNVector3(Float((pt.x-center.x)/1000),Float((pt.y-center.y)/1000),
                              Float((pt.z-center.z)/1000))
        }
        // SceneKit UV bottom-left origin; slice raster has top-left origin.
        let uv:[CGPoint]=[CGPoint(x:0,y:1),CGPoint(x:1,y:1),CGPoint(x:0,y:0),CGPoint(x:1,y:0)]
        let source=SCNGeometrySource(vertices:vertices)
        let texture=SCNGeometrySource(textureCoordinates:uv)
        let element=SCNGeometryElement(indices:[UInt32(0),1,2,2,1,3],primitiveType:.triangles)
        let geometry=SCNGeometry(sources:[source,texture],elements:[element])
        let material=SCNMaterial()
        material.diffuse.contents=UIImage(cgImage:image)
        material.lightingModel = .constant
        material.doubleSided=true
        material.transparency=0.72
        material.writesToDepthBuffer=false
        geometry.firstMaterial=material
        let node=SCNNode(geometry:geometry)
        node.name="MRI \(plane.rawValue) physical slice (unvalidated)"
        return node
    }

    private func surfaceNode(_ mesh:PreviewSurface,center:Point3,color:UIColor) -> SCNNode {
        let pts=mesh.verticesMm
        var verts:[SCNVector3]=[]; var normals:[SCNVector3]=[]
        verts.reserveCapacity(pts.count);normals.reserveCapacity(pts.count)
        for i in stride(from:0,to:pts.count,by:3) {
            guard i+2<pts.count else { break }
            let a=pts[i],b=pts[i+1],c=pts[i+2]
            let u=SIMD3<Float>(Float(b.x-a.x),Float(b.y-a.y),Float(b.z-a.z))
            let v=SIMD3<Float>(Float(c.x-a.x),Float(c.y-a.y),Float(c.z-a.z))
            let n=simd_normalize(simd_cross(u,v))
            for p in [a,b,c] {
                verts.append(SCNVector3(Float((p.x-center.x)/1000),Float((p.y-center.y)/1000),
                                        Float((p.z-center.z)/1000)))
                normals.append(SCNVector3(n.x,n.y,n.z))
            }
        }
        let indices=(0..<verts.count).map { UInt32($0) }
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:verts),
                                          SCNGeometrySource(normals:normals)],
                                 elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let material=SCNMaterial()
        material.diffuse.contents=color
        material.doubleSided=true
        material.lightingModel = .constant
        material.transparency=CGFloat(color.cgColor.alpha)
        material.writesToDepthBuffer=false
        geometry.firstMaterial=material
        return SCNNode(geometry:geometry)
    }

    private func sphere(at p:SCNVector3,radius:CGFloat,color:UIColor)->SCNNode {
        let material=SCNMaterial();material.diffuse.contents=color
        let ball=SCNSphere(radius:radius);ball.firstMaterial=material
        let node=SCNNode(geometry:ball);node.position=p
        return node
    }

    private func cylinder(from a:SCNVector3,to b:SCNVector3,radius:CGFloat,color:UIColor)->SCNNode {
        let v=SIMD3<Float>(b.x-a.x,b.y-a.y,b.z-a.z)
        let length=simd_length(v)
        let node=SCNNode()
        guard length>0.00001 else { return node }
        let material=SCNMaterial();material.diffuse.contents=color
        let mesh=SCNCylinder(radius:radius,height:CGFloat(length));mesh.firstMaterial=material
        node.geometry=mesh
        node.position=SCNVector3((a.x+b.x)*0.5,(a.y+b.y)*0.5,(a.z+b.z)*0.5)
        node.simdOrientation=simd_quatf(from:SIMD3<Float>(0,1,0),to:simd_normalize(v))
        return node
    }
}
