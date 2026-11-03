import Foundation
import SwiftUI
import Metal
import MetalKit
import ARKit
import SceneKit
import GeometryCore
import simd

/// GPU rendering of genuine scalar voxels. No segmentation is inferred.
/// Uniform layout must exactly match VolumeUniforms in VolumeRaymarch.metal.
struct VolumeGPUUniforms {
    var inverseViewProjection = matrix_identity_float4x4
    var worldToTexture = matrix_identity_float4x4
    var worldToCamera = matrix_identity_float4x4
    var depthAffineU = SIMD4<Float>(1,0,0,0)
    var depthAffineV = SIMD4<Float>(0,1,0,0)
    var window = SIMD4<Float>(0,1,0.25,1)
    var options = SIMD4<UInt32>(0,120,0,0)
}

enum VolumeDisplayMode: Int, CaseIterable, Identifiable {
    case composite = 0
    case maximumIntensity = 1
    case isoSurface = 2

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .composite: return "Volume"
        case .maximumIntensity: return "MIP"
        case .isoSurface: return "Surface"
        }
    }
}

/// Everything below the data transfer, including 3D interpolation, DVR,
/// maximum-intensity projection and iso-surface sampling, runs on Metal.
/// The downsampled texture retains source affine geometry (mm -> meters).
final class MedicalVolumeRenderer: NSObject, MTKViewDelegate {
    enum CameraSource { case studio, tabletop }
    let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let commandQueue: MTLCommandQueue
    private(set) var texture: MTLTexture?
    private var depthTexture: MTLTexture
    private(set) var unitToLocal = matrix_identity_float4x4
    private var lastVolumeRevision = -1
    private var uploadEpoch = 0
    weak var arView: ARSCNView?
    var source: CameraSource = .studio
    var anchorTransform: simd_float4x4?
    var window: ClosedRange<Float> = 0...200
    var displayMode: VolumeDisplayMode = .composite
    var threshold: Float = 0.27
    var opacity: Float = 1
    var quality: UInt32 = 128
    var isActive = true
    var useSceneDepth = true

    // Manipulate a model relative to a persistent anchor. Hand and touch
    // interactions NEVER overwrite anchor coordinates or camera transforms.
    var modelOffset = SIMD3<Float>(repeating: 0)
    var modelEuler = SIMD3<Float>(repeating: 0)
    var modelScale: Float = 1
    var studioYaw: Float = -0.42
    var studioPitch: Float = 0.16
    var studioDistance: Float = 0.48

    init?() {
        guard let gpu = MTLCreateSystemDefaultDevice(),
              let library = gpu.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "neuroVolumeVertex"),
              let fragment = library.makeFunction(name: "neuroVolumeFragment"),
              let queue = gpu.makeCommandQueue() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let compiled = try? gpu.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let blankDepth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        blankDepth.usage = [.shaderRead]
        guard let fallback = gpu.makeTexture(descriptor: blankDepth) else { return nil }
        var zero: Float = 0
        withUnsafeBytes(of: &zero) { raw in
            fallback.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0,
                             withBytes: raw.baseAddress!, bytesPerRow: MemoryLayout<Float>.stride)
        }
        device = gpu
        pipeline = compiled
        commandQueue = queue
        depthTexture = fallback
        super.init()
    }

    func configure(view: MTKView, transparent: Bool) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = !transparent
        view.backgroundColor = transparent ? .clear : UIColor(red:0.022,green:0.037,blue:0.058,alpha:1)
        view.layer.isOpaque = !transparent
        view.clearColor = transparent
            ? MTLClearColorMake(0,0,0,0)
            : MTLClearColorMake(0.022,0.037,0.058,1)
        // ~60% native resolution; full quality source voxels remain in 3D GPU
        // texture. This saves fragment work and heat on current iPhones.
        view.contentScaleFactor = max(1.0, UIScreen.main.scale * 0.60)
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = self
    }

    private struct VolumeUpload {
        let dimensions: [Int]
        let halfBits: [UInt16]
        let unitToLocal: simd_float4x4
    }

    /// Preparation is off-main: millions of Float -> Float16 conversions
    /// must not delay SwiftUI or ARKit tracking. Only the latest request wins.
    func load(_ volume: VoxelVolume, revision: Int) {
        guard revision != lastVolumeRevision else { return }
        lastVolumeRevision = revision
        uploadEpoch += 1
        let token = uploadEpoch
        texture = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let upload = Self.makeUpload(volume)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.uploadEpoch == token, let upload else { return }
                let dims = upload.dimensions
                let desc = MTLTextureDescriptor()
                desc.textureType = .type3D
                desc.pixelFormat = .r16Float
                desc.width = dims[0]
                desc.height = dims[1]
                desc.depth = dims[2]
                desc.mipmapLevelCount = 1
                desc.usage = [.shaderRead]
                desc.storageMode = .shared
                guard let result = self.device.makeTexture(descriptor: desc) else { return }
                upload.halfBits.withUnsafeBytes { raw in
                    result.replace(
                        region: MTLRegionMake3D(0,0,0,dims[0],dims[1],dims[2]),
                        mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!,
                        bytesPerRow: dims[0] * MemoryLayout<UInt16>.stride,
                        bytesPerImage: dims[0] * dims[1] * MemoryLayout<UInt16>.stride)
                }
                self.unitToLocal = upload.unitToLocal
                self.texture = result
            }
        }
    }

    private static func makeUpload(_ volume: VoxelVolume) -> VolumeUpload? {
        let sourceDims = volume.dimensions
        guard sourceDims.count == 3, sourceDims.allSatisfy({ $0 > 1 }) else { return nil }
        var stride = 1
        func side(_ dim: Int) -> Int { (dim - 1) / stride + 1 }
        // 8.4 million half-precision texels = ~16 MiB GPU residency.
        while Double(side(sourceDims[0])) * Double(side(sourceDims[1])) *
                Double(side(sourceDims[2])) > 8_388_608 {
            stride += 1
        }
        let dims = sourceDims.map(side)
        var half = [UInt16](repeating: 0, count: dims[0]*dims[1]*dims[2])
        for k in 0..<dims[2] {
            for j in 0..<dims[1] {
                for i in 0..<dims[0] {
                    let index = (k*stride*sourceDims[1] + j*stride) * sourceDims[0] + i*stride
                    let value = volume.voxels[index]
                    let clamped = value.isFinite ? min(65504, max(-65504, value)) : 0
                    half[(k*dims[1]+j)*dims[0]+i] = Float16(clamped).bitPattern
                }
            }
        }
        let center = volume.bounds.center
        let affine = volume.affine
        func scaled(_ p: Point3, _ n: Double) -> SIMD4<Float> {
            SIMD4<Float>(Float(p.x*n/1000), Float(p.y*n/1000), Float(p.z*n/1000), 0)
        }
        var model = matrix_identity_float4x4
        model.columns.0 = scaled(affine.iMm, Double((dims[0]-1)*stride))
        model.columns.1 = scaled(affine.jMm, Double((dims[1]-1)*stride))
        model.columns.2 = scaled(affine.kMm, Double((dims[2]-1)*stride))
        model.columns.3 = SIMD4<Float>(
            Float((affine.originMm.x-center.x)/1000),
            Float((affine.originMm.y-center.y)/1000),
            Float((affine.originMm.z-center.z)/1000), 1)
        return VolumeUpload(dimensions: dims, halfBits: half, unitToLocal: model)
    }

    func resetInteraction() {
        modelOffset = SIMD3<Float>(repeating: 0)
        modelEuler = SIMD3<Float>(repeating: 0)
        modelScale = 1
    }

    func moveInView(dx: Float, dy: Float) {
        guard anchorTransform != nil || source == .studio else { return }
        // View-plane translations are intentionally bounded around the anchor.
        modelOffset.x = min(0.18,max(-0.18,modelOffset.x + dx))
        modelOffset.y = min(0.18,max(-0.18,modelOffset.y + dy))
    }

    func rotate(dx: Float, dy: Float, roll: Float = 0) {
        modelEuler.y += min(0.16,max(-0.16,dx))
        modelEuler.x += min(0.16,max(-0.16,dy))
        modelEuler.z += min(0.16,max(-0.16,roll))
    }

    func scale(by factor: Float) {
        guard factor.isFinite else { return }
        modelScale = min(3.0, max(0.35,modelScale * min(1.16,max(0.86,factor))))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Always clear the drawable when tracking is lost or a new volume is
        // uploading; otherwise a stale layer can appear to "skate" in AR.
        guard isActive, let texture else {
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
            return
        }
        var uniform = VolumeGPUUniforms()
        let viewMatrix: simd_float4x4
        let projection: simd_float4x4
        let rootTransform: simd_float4x4
        var depthMap: CVPixelBuffer?
        var frame: ARFrame?

        switch source {
        case .studio:
            let aspect = Float(max(view.bounds.width,1) / max(view.bounds.height,1))
            let eye = SIMD3<Float>(
                studioDistance * sin(studioYaw) * cos(studioPitch),
                studioDistance * sin(studioPitch),
                studioDistance * cos(studioYaw) * cos(studioPitch))
            let z = simd_normalize(eye)
            let x = simd_normalize(simd_cross(SIMD3<Float>(0,1,0),z))
            let y = simd_cross(z,x)
            let cameraToWorld = simd_float4x4(
                SIMD4<Float>(x,0), SIMD4<Float>(y,0),
                SIMD4<Float>(z,0), SIMD4<Float>(eye,1))
            viewMatrix = simd_inverse(cameraToWorld)
            projection = Self.perspective(fovY: 0.90, aspect: aspect, near: 0.01, far: 6)
            rootTransform = matrix_identity_float4x4
        case .tabletop:
            guard let arView, let anchorTransform,
                  let current = arView.session.currentFrame else {
                encoder.endEncoding()
                command.present(drawable)
                command.commit()
                return
            }
            guard case .normal = current.camera.trackingState else {
                encoder.endEncoding()
                command.present(drawable)
                command.commit()
                return
            }
            frame = current
            let area = arView.bounds.size
            viewMatrix = current.camera.viewMatrix(for: .portrait)
            projection = current.camera.projectionMatrix(
                for: .portrait, viewportSize: area, zNear: 0.01, zFar: 8)
            rootTransform = anchorTransform * Self.translation(SIMD3<Float>(0,0.14,0))
            if useSceneDepth, let depth = current.smoothedSceneDepth?.depthMap,
               CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 {
                depthMap = depth
            }
        }

        // The object is stationary in its anchor frame; updating the iPhone's
        // view matrix moves the CAMERA, not the anatomy.
        let rx = simd_float4x4(simd_quatf(angle: modelEuler.x,axis: SIMD3<Float>(1,0,0)))
        let ry = simd_float4x4(simd_quatf(angle: modelEuler.y,axis: SIMD3<Float>(0,1,0)))
        let rz = simd_float4x4(simd_quatf(angle: modelEuler.z,axis: SIMD3<Float>(0,0,1)))
        let scale = Self.uniformScale(modelScale)
        let modelToWorld = rootTransform * Self.translation(modelOffset) * rz * ry * rx *
            scale * unitToLocal
        let determinant = simd_determinant(modelToWorld)
        guard determinant.isFinite, abs(determinant) > 1e-12 else {
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
            return
        }
        uniform.worldToTexture = simd_inverse(modelToWorld)
        uniform.worldToCamera = viewMatrix
        uniform.inverseViewProjection = simd_inverse(projection * viewMatrix)
        uniform.window = SIMD4<Float>(window.lowerBound,window.upperBound,
                                      threshold,opacity)
        uniform.options = SIMD4<UInt32>(UInt32(displayMode.rawValue), quality, 0,0)

        if let depthMap, let frame, let arView {
            let w = CVPixelBufferGetWidth(depthMap)
            let h = CVPixelBufferGetHeight(depthMap)
            if depthTexture.width != w || depthTexture.height != h {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r32Float,width:w,height:h,mipmapped:false)
                desc.usage = [.shaderRead]
                desc.storageMode = .shared
                if let newTex = device.makeTexture(descriptor:desc) { depthTexture = newTex }
            }
            if depthTexture.width == w && depthTexture.height == h {
                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                if let bytes = CVPixelBufferGetBaseAddress(depthMap) {
                    depthTexture.replace(region:MTLRegionMake2D(0,0,w,h),
                                         mipmapLevel:0,withBytes:bytes,
                                         bytesPerRow:CVPixelBufferGetBytesPerRow(depthMap))
                    let map = frame.displayTransform(
                        for:.portrait,viewportSize:arView.bounds.size).inverted()
                    uniform.depthAffineU = SIMD4<Float>(Float(map.a),Float(map.c),Float(map.tx),0)
                    uniform.depthAffineV = SIMD4<Float>(Float(map.b),Float(map.d),Float(map.ty),0)
                    uniform.options.z = 1
                }
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            }
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture,index:0)
        encoder.setFragmentTexture(depthTexture,index:1)
        withUnsafeBytes(of:&uniform) { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!,length:bytes.count,index:0)
        }
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private static func translation(_ p: SIMD3<Float>) -> simd_float4x4 {
        var result = matrix_identity_float4x4
        result.columns.3 = SIMD4<Float>(p,1)
        return result
    }

    private static func uniformScale(_ value: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(value,0,0,0), SIMD4<Float>(0,value,0,0),
            SIMD4<Float>(0,0,value,0), SIMD4<Float>(0,0,0,1))
    }

    private static func perspective(fovY: Float, aspect: Float,
                                    near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / max(aspect,0.1)
        return simd_float4x4(
            SIMD4<Float>(x,0,0,0),
            SIMD4<Float>(0,y,0,0),
            SIMD4<Float>(0,0,far/(near-far),-1),
            SIMD4<Float>(0,0,far*near/(near-far),0))
    }
}

struct VolumeStudioCanvas: UIViewRepresentable {
    @ObservedObject var imaging: MRIPlanningModel
    @Binding var displayMode: VolumeDisplayMode
    @Binding var threshold: Double
    @Binding var opacity: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        if let renderer = context.coordinator.renderer {
            renderer.source = .studio
            renderer.configure(view:view,transparent:false)
            context.coordinator.attachGestures(to:view)
            renderer.load(imaging.volume,revision:imaging.volumeRevision)
            renderer.window = imaging.window
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        guard let renderer=context.coordinator.renderer else { return }
        renderer.load(imaging.volume,revision:imaging.volumeRevision)
        renderer.window = imaging.window
        renderer.displayMode = displayMode
        renderer.threshold = Float(threshold)
        renderer.opacity = Float(opacity)
    }

    final class Coordinator: NSObject {
        let renderer = MedicalVolumeRenderer()
        weak var view: MTKView?

        func attachGestures(to view: MTKView) {
            self.view = view
            let pan = UIPanGestureRecognizer(target:self,action:#selector(rotate(_:)))
            pan.maximumNumberOfTouches = 1
            let pinch = UIPinchGestureRecognizer(target:self,action:#selector(zoom(_:)))
            let roll = UIRotationGestureRecognizer(target:self,action:#selector(twist(_:)))
            for gesture in [pan,pinch,roll] { view.addGestureRecognizer(gesture) }
        }

        @objc private func rotate(_ sender: UIPanGestureRecognizer) {
            guard let view,let renderer else { return }
            let point = sender.translation(in:view)
            if sender.state == .changed {
                renderer.studioYaw -= Float(point.x) * 0.007
                renderer.studioPitch = min(1.42,max(-1.42,
                    renderer.studioPitch + Float(point.y) * 0.006))
            }
            sender.setTranslation(.zero,in:view)
        }

        @objc private func zoom(_ sender: UIPinchGestureRecognizer) {
            if sender.state == .changed,let renderer {
                renderer.studioDistance = min(1.8,max(0.12,
                    renderer.studioDistance / Float(sender.scale)))
            }
            sender.scale = 1
        }

        @objc private func twist(_ sender: UIRotationGestureRecognizer) {
            if sender.state == .changed,let renderer {
                renderer.rotate(dx:0,dy:0,roll:-Float(sender.rotation))
            }
            sender.rotation = 0
        }
    }
}


/// Compact instance of the same GPU renderer in the Study workspace.
/// Keeps heavy Metal code out of the large SwiftUI MRI editor expression.
struct EmbeddedVolumePreview: View {
    @ObservedObject var imaging: MRIPlanningModel
    @State private var mode: VolumeDisplayMode = .composite
    @State private var cutoff = 0.28
    @State private var density = 1.0

    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Label("TRUE VOLUMETRIC CT / MRI",systemImage:"cube.transparent")
                    .font(.caption.weight(.bold))
                Spacer()
                Text("GPU RAYMARCH").font(.caption2.monospaced())
                    .foregroundStyle(.teal)
            }
            VolumeStudioCanvas(imaging:imaging,displayMode:$mode,
                               threshold:$cutoff,opacity:$density)
                .frame(height:335)
                .clipShape(RoundedRectangle(cornerRadius:12))
            Picker("Method",selection:$mode) {
                ForEach(VolumeDisplayMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }.pickerStyle(.segmented)
            HStack {
                Text("Threshold").font(.caption).frame(width:72,alignment:.leading)
                Slider(value:$cutoff,in:0.01...0.95)
            }
            if mode == .composite {
                HStack {
                    Text("Opacity").font(.caption).frame(width:72,alignment:.leading)
                    Slider(value:$density,in:0.2...3.0)
                }
            }
            Text("Renders actual imported voxels with GPU compositing, MIP or intensity iso-surface. No anatomical skull or brain segmentation is inferred.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}


/// Keep the older, geometric annotation preview available for existing
/// trajectory/ROI workflows, but not confused with direct voxel rendering.
struct LegacyGeometryControls: View {
    @ObservedObject var model: MRIPlanningModel

    var body: some View {
        DisclosureGroup("Trajectory / ROI geometric diagnostic") {
            VStack(alignment:.leading,spacing:8) {
                TrajectorySceneView(
                    volume:model.volume,revision:model.volumeRevision,
                    maskRevision:model.maskRevision,mask:model.mask,
                    cursorMm:model.cursorMm,window:model.window,
                    tissueSurface:model.tissueSurface,
                    maskSurface:model.maskSurface,
                    showSlices:model.showSlices3D,
                    showTissue:model.showIntensity3D,
                    showMask:model.showROI3D,
                    entryMm:model.entryMm,targetMm:model.targetMm,
                    tipMm:model.path.atDepth(model.depthMm))
                    .frame(height:265)
                    .clipShape(RoundedRectangle(cornerRadius:12))
                HStack {
                    Toggle("Slices",isOn:$model.showSlices3D)
                    Toggle("Threshold surface",isOn:$model.showIntensity3D)
                }.font(.caption)
                Toggle("External mask surface",isOn:$model.showROI3D)
                    .disabled(model.mask == nil).font(.caption)
                Toggle("Mask explicitly denotes external scalp",isOn:$model.maskIsScalp)
                    .font(.caption).disabled(model.mask == nil)
                HStack {
                    Text("Threshold")
                    Spacer()
                    Text(String(format:"%.0f",model.isoThreshold))
                }.font(.caption)
                Slider(value:$model.isoThreshold,
                       in:Double(model.window.lowerBound)...max(
                           Double(model.window.lowerBound)+1,
                           Double(model.window.upperBound)),step:1)
                Button(model.surfaceBusy ? "Extracting…" : "Rebuild diagnostic mesh") {
                    model.rebuildPreview()
                }.disabled(model.surfaceBusy)
                Text(model.surfaceStatus).font(.caption2.monospaced())
                Text("The intensity cutoff is not a verified tissue, bone, brain, vessel or scalp segmentation. Geometric display/ROI previews have not been validated for navigation.")
                    .font(.caption2).foregroundStyle(.orange)
            }.padding(.top,6)
        }.tint(.teal)
    }
}
