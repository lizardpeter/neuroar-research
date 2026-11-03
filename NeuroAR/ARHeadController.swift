import Foundation
import UIKit
import Combine
import ARKit
import RealityKit
import simd
import GeometryCore

final class ARHeadController: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var study: Study = .synthetic
    @Published private(set) var selectedIndex = 0
    @Published private(set) var capturedPoints: [Point3] = []
    @Published private(set) var registration: RegistrationResult?
    @Published private(set) var heldOutSurfaceResidualMeters: Double?
    @Published private(set) var status = "Point the rear camera toward a stationary head."
    @Published private(set) var lidarSupported = false
    @Published private(set) var trackingIsNormal = false
    @Published private(set) var depthMm = 30.0
    @Published private(set) var meshImported = false
    @Published private(set) var plannerLinked = false

    weak var arView: ARView?
    private var root: Entity?
    private var anchor: AnchorEntity?
    private var customMesh: Entity?
    private var intensityPreview: Entity?
    private var roiPreview: Entity?
    private var markerAnchors: [AnchorEntity] = []
    private var lastTrackingNormal = false
    private var frameCount = 0

    var nextLandmark: StudyLandmark? {
        capturedPoints.count < study.landmarks.count ? study.landmarks[capturedPoints.count] : nil
    }
    var activeTrajectory: StudyTrajectory? {
        study.trajectories.indices.contains(selectedIndex) ? study.trajectories[selectedIndex] : nil
    }

    func connect(to view: ARView) {
        clearRegistration(reason:"New AR session. Capture synthetic phantom landmarks again.")
        self.arView = view
        view.automaticallyConfigureSession = false
        view.session.delegate = self
        lidarSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        guard lidarSupported else {
            status = "Requires a LiDAR-equipped iPhone or iPad for landmark capture."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        config.worldAlignment = .gravity
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func disconnect(from view: ARView) {
        view.session.pause()
        if arView === view {
            clearRegistration(reason:"AR camera closed; all world-space landmarks invalidated.")
            arView=nil
            trackingIsNormal=false
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard frameCount % 12 == 0 else { return }
        let normal: Bool
        switch frame.camera.trackingState {
        case .normal: normal = true
        default: normal = false
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trackingIsNormal = normal
            if self.lastTrackingNormal && !normal && self.registration != nil {
                self.clearRegistration(reason:"Tracking interrupted. Re-register before visualizing.")
            }
            self.lastTrackingNormal = normal
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.clearRegistration(reason:"Session interrupted. Registration cleared.")
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.clearRegistration(reason:"AR session failed: \(error.localizedDescription)")
        }
    }

    func captureLandmark(at location: CGPoint, viewportSize: CGSize) {
        guard lidarSupported, trackingIsNormal else {
            status = "LiDAR and normal camera tracking are required."
            return
        }
        guard nextLandmark != nil, let arView, let frame = arView.session.currentFrame else { return }
        let orientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        do {
            let point = try DepthUnprojector.worldPoint(at:location,
                    viewportSize:viewportSize,orientation:orientation,frame:frame)
            capturedPoints.append(point)
            let marker=AnchorEntity(world:SIMD3<Float>(Float(point.x),Float(point.y),Float(point.z)))
            marker.addChild(ModelEntity(mesh:.generateSphere(radius:0.004),
                                        materials:[SimpleMaterial(color:.systemYellow,isMetallic:false)]))
            arView.scene.addAnchor(marker)
            markerAnchors.append(marker)
            status = "Landmark \(capturedPoints.count) of \(study.landmarks.count) captured."
            if capturedPoints.count == study.landmarks.count { fitLandmarks() }
        } catch {
            status = error.localizedDescription
        }
    }

    private func fitLandmarks() {
        do {
            let sources = study.landmarks.map {
                Point3($0.pointMm.x/1000,$0.pointMm.y/1000,$0.pointMm.z/1000)
            }
            let report = try LandmarkRegistrationEvaluator.evaluate(sourceMeters:sources,targetMeters:capturedPoints)
            let result = report.fit
            // A low landmark-fit error does NOT establish clinical target registration accuracy.
            // Thresholds here are demonstration guards, not surgical acceptance criteria.
            guard result.landmarkRMSEmeters <= 0.015 else {
                clearRegistration(reason:"Landmark fit exceeds the 15 mm demonstration guard. Retake points.")
                return
            }
            if let residual=report.heldOutSurfaceResidualMeters, residual > 0.03 {
                clearRegistration(reason:"Independent surface landmark mismatch >30 mm (demo guard). Retake the entire correspondence set. Not clinical accuracy.")
                return
            }
            registration=result
            heldOutSurfaceResidualMeters=report.heldOutSurfaceResidualMeters
            status=String(format:"Demo fit residual %.1f mm; \(report.hasHeldOutPoint ? "last external landmark held out" : "NO independent landmark check"). NOT intracranial accuracy.",result.landmarkRMSEmeters*1000)
            render()
        } catch {
            clearRegistration(reason:"Could not fit landmarks: \(error.localizedDescription)")
        }
    }

    func clearRegistration(reason: String = "Registration reset. Retake landmarks.") {
        registration=nil; heldOutSurfaceResidualMeters=nil;capturedPoints=[]
        markerAnchors.forEach { $0.removeFromParent() }
        markerAnchors=[]
        anchor?.removeFromParent(); anchor=nil; root=nil
        status=reason
    }

    func importStudy(url: URL) {
        let opened=url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        do {
            let data=try Data(contentsOf:url)
            let loaded=try JSONDecoder().decode(Study.self,from:data)
            guard loaded.landmarks.count >= 3, !loaded.trajectories.isEmpty,
                loaded.landmarks.allSatisfy({ $0.pointMm.allFinite }),
                loaded.trajectories.allSatisfy({ $0.entryMm.allFinite && $0.targetMm.allFinite }) else {
                status="Invalid study: needs three landmarks and finite trajectories."
                return
            }
            study=loaded; selectedIndex=0; depthMm=min(30,loaded.trajectories[0].lengthMm)
            customMesh=nil; intensityPreview=nil; roiPreview=nil
            plannerLinked=false; meshImported=false
            clearRegistration(reason:"Loaded \(loaded.title). Capture corresponding facial landmarks.")
        } catch { status="Study import error: \(error.localizedDescription)" }
    }

    /// Explicit bridge from the *same image* used in the MRI planner.
    /// A fresh landmark registration is mandatory and any prior world-space
    /// anchor is invalidated. This is visualization, NOT instrument guidance.
    func importPlanningStudy(study planned:Study, intensitySurface:PreviewSurface?,
                             roiSurface:PreviewSurface?, displayedDepthMm:Double) {
        clearRegistration(reason:"MRI planning study linked. Capture the corresponding physical head landmarks in the displayed order. Unvalidated research mode.")
        study=planned
        selectedIndex=0
        depthMm=min(max(0,displayedDepthMm),planned.trajectories.first?.lengthMm ?? 0)
        customMesh=nil;meshImported=false
        plannerLinked=true
        // Bound geometry for phone memory. Coarse previews never establish anatomy.
        intensityPreview=makePreviewEntity(intensitySurface,color:UIColor.systemGray.withAlphaComponent(0.35))
        roiPreview=makePreviewEntity(roiSurface,color:UIColor.systemCyan.withAlphaComponent(0.45))
        if intensityPreview == nil && roiPreview == nil {
            status += " No segmented 3D surface available; trajectories and landmarks only."
        }
    }

    func invalidatePlanningLink() {
        guard plannerLinked else { return }
        clearRegistration(reason:"MRI image changed. AR study and registration invalidated; relink the new MRI explicitly.")
        study = .synthetic
        selectedIndex = 0
        depthMm = 30
        intensityPreview=nil;roiPreview=nil
        plannerLinked=false
    }

    private func makePreviewEntity(_ preview:PreviewSurface?,color:UIColor)->Entity? {
        guard let preview, !preview.verticesMm.isEmpty else { return nil }
        let limit = min(preview.verticesMm.count/3, 12_000)
        guard limit > 0 else { return nil }
        let positions:[SIMD3<Float>] = preview.verticesMm.prefix(limit*3).map { p in
            SIMD3<Float>(Float(p.x/1000),Float(p.y/1000),Float(p.z/1000))
        }
        var meshDescriptor = MeshDescriptor(name:"Unvalidated coarse MRI preview")
        meshDescriptor.positions = MeshBuffers.Positions(positions)
        meshDescriptor.primitives = .triangles((0..<positions.count).map { UInt32($0) })
        do {
            let mesh = try MeshResource.generate(from:[meshDescriptor])
            return ModelEntity(mesh:mesh,materials:[SimpleMaterial(color:color,isMetallic:false)])
        } catch {
            status="3D AR preview unavailable: \(error.localizedDescription). Landmarks and paths remain available."
            return nil
        }
    }

    func importMesh(url: URL) {
        Task { @MainActor in
            let access=url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let entity=try await Entity(contentsOf:url)
                // Imported USDZ geometry MUST already use MRI coordinates in METERS.
                // 1 mm in study JSON corresponds to 0.001 unit in the mesh.
                customMesh=entity
                meshImported=true
                status="Anatomy mesh loaded. Registration required for overlay."
                render()
            } catch { status="USDZ import error: \(error.localizedDescription)" }
        }
    }

    func selectTrajectory(_ idx: Int) {
        guard study.trajectories.indices.contains(idx) else { return }
        selectedIndex=idx
        depthMm=min(30,study.trajectories[idx].lengthMm)
        render()
    }
    func setDepth(_ value: Double) {
        depthMm=max(0,min(value,activeTrajectory?.lengthMm ?? 0))
        render()
    }
    func coordinate(entry: Bool, axis: Int) -> Double {
        guard let tr=activeTrajectory else { return 0 }
        return entry ? tr.entryMm[axis] : tr.targetMm[axis]
    }
    func setCoordinate(entry: Bool, axis: Int, value: Double) {
        guard study.trajectories.indices.contains(selectedIndex), axis >= 0, axis < 3 else { return }
        if entry { study.trajectories[selectedIndex].entryMm[axis]=value }
        else { study.trajectories[selectedIndex].targetMm[axis]=value }
        depthMm=min(depthMm,activeTrajectory?.lengthMm ?? 0)
        render()
    }

    private func render() {
        anchor?.removeFromParent(); anchor=nil; root=nil
        guard let registration,let arView else { return }
        let sceneAnchor=AnchorEntity(world:.zero)
        let sceneRoot=Entity()
        let q=registration.quaternionWXYZ
        sceneRoot.orientation=simd_quatf(ix:Float(q[1]),iy:Float(q[2]),iz:Float(q[3]),r:Float(q[0]))
        let t=registration.translationMeters
        sceneRoot.position=SIMD3<Float>(Float(t.x),Float(t.y),Float(t.z))
        sceneAnchor.addChild(sceneRoot)
        arView.scene.addAnchor(sceneAnchor)
        anchor=sceneAnchor; root=sceneRoot

        if plannerLinked {
            if let intensityPreview {
                intensityPreview.removeFromParent()
                sceneRoot.addChild(intensityPreview)
            }
            if let roiPreview {
                roiPreview.removeFromParent()
                sceneRoot.addChild(roiPreview)
            }
        } else if let customMesh {
            customMesh.removeFromParent()
            sceneRoot.addChild(customMesh)
        } else if study.isSynthetic {
            // Synthetic model, NOT reconstructed patient anatomy.
            let brain=ModelEntity(mesh:.generateSphere(radius:1),
                materials:[SimpleMaterial(color:UIColor.systemTeal.withAlphaComponent(0.42),isMetallic:false)])
            brain.scale=SIMD3<Float>(0.072,0.088,0.076)
            sceneRoot.addChild(brain)
        }
        guard let plan=activeTrajectory else { return }
        let entry=meters(plan.entryMm), target=meters(plan.targetMm)
        let tip=meters(plan.atDepth(depthMm))
        sceneRoot.addChild(ball(at:entry,radius:0.005,color:.systemOrange))
        sceneRoot.addChild(ball(at:target,radius:0.004,color:.systemPurple))
        sceneRoot.addChild(ball(at:tip,radius:0.005,color:.systemYellow))
        if simd_distance(entry,tip) > 0.001 {
            sceneRoot.addChild(segment(from:entry,to:tip,radius:0.0015,color:.systemYellow))
        }
        if simd_distance(tip,target) > 0.001 {
            sceneRoot.addChild(segment(from:tip,to:target,radius:0.00065,color:.systemGray))
        }
    }
    private func meters(_ p: Point3) -> SIMD3<Float> {
        SIMD3<Float>(Float(p.x/1000),Float(p.y/1000),Float(p.z/1000))
    }
    private func ball(at p: SIMD3<Float>,radius:Float,color:UIColor) -> Entity {
        let entity=ModelEntity(mesh:.generateSphere(radius:radius),materials:[SimpleMaterial(color:color,isMetallic:false)])
        entity.position=p
        return entity
    }
    private func segment(from a:SIMD3<Float>,to b:SIMD3<Float>,radius:Float,color:UIColor) -> Entity {
        let delta=b-a
        let length=simd_length(delta)
        let entity=ModelEntity(mesh:.generateCylinder(height:length,radius:radius),
                               materials:[SimpleMaterial(color:color,isMetallic:false)])
        entity.position=(a+b)/2
        entity.orientation=simd_quatf(from:SIMD3<Float>(0,1,0),to:simd_normalize(delta))
        return entity
    }
}
