import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers
import GeometryCore

/// The imaging workspace is independent of the live AR registration. Imported
/// scans are NOT assumed to match any previously loaded landmarks or USDZ.
final class MRIPlanningModel: ObservableObject {
    enum EditMode: String, CaseIterable {
        case cursor = "Crosshair"
        case entry = "Entry"
        case target = "Target"
    }

    @Published private(set) var volume = VoxelVolume.syntheticDemo()
    @Published private(set) var mask: VoxelVolume?
    @Published var maskIsScalp = false
    @Published private(set) var tissueSurface: PreviewSurface?
    @Published private(set) var maskSurface: PreviewSurface?
    @Published private(set) var surfaceStatus = "3D preview not yet generated"
    @Published private(set) var surfaceBusy = false
    @Published private(set) var volumeRevision = 0
    @Published private(set) var maskRevision = 0
    @Published var isoThreshold: Double = 95
    @Published var showSlices3D = true
    @Published var showIntensity3D = false
    @Published var showROI3D = true
    private var surfaceRequest = 0
    private struct SliceCacheKey: Equatable {
        let imageVersion: Int
        let maskVersion: Int
        let x: Double
        let y: Double
        let z: Double
        let low: Float
        let high: Float
    }
    private var sliceCache: [ImagingPlane: (key: SliceCacheKey, value: SliceRaster)] = [:]

    func sliceRaster(for plane: ImagingPlane) -> SliceRaster {
        let key = SliceCacheKey(imageVersion: volumeRevision, maskVersion: maskRevision,
                                x: cursorMm.x, y: cursorMm.y, z: cursorMm.z,
                                low: lowWindow, high: highWindow)
        if let cached = sliceCache[plane], cached.key == key { return cached.value }
        let raster = SliceRenderer.render(volume: volume, mask: mask, plane: plane,
                                          cursor: cursorMm, window: window,
                                          width: 176, height: 176)
        sliceCache[plane] = (key: key, value: raster)
        return raster
    }
    @Published private(set) var cursorMm = Point3(0,0,0)
    @Published private(set) var entryMm = Point3(30,65,32)
    @Published private(set) var targetMm = Point3(5,0,4)
    @Published var editMode: EditMode = .cursor
    @Published private(set) var depthMm = 30.0
    @Published private(set) var candidates:[StudyTrajectory]=[]
    @Published private(set) var landmarks:[StudyLandmark]=[]
    @Published private(set) var selectedCandidateID:String?
    @Published private(set) var lowWindow: Float = 0
    @Published private(set) var highWindow: Float = 200
    @Published private(set) var loading = false
    @Published private(set) var status = "Synthetic anatomical phantom. Import a NIfTI scan to start a study."

    func addLandmark(name: String) {
        guard landmarks.count < 64 else { status="Maximum of 64 research landmarks reached."; return }
        guard volume.nearest(at:cursorMm) != nil else { status="Select a point within the image first."; return }
        let label = String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(100))
        guard !label.isEmpty else { status="Enter a landmark label first."; return }
        // Re-annotating a named feature replaces its previous position instead
        // of creating ambiguous same-name correspondences for registration.
        if let index = landmarks.firstIndex(where: { $0.name.caseInsensitiveCompare(label) == .orderedSame }) {
            let prior = landmarks[index]
            landmarks[index] = StudyLandmark(id: prior.id, name: label, pointMm: cursorMm)
            status = "Landmark updated at crosshair. Confirm the MRI feature location."
        } else {
            landmarks.append(StudyLandmark(id: UUID().uuidString, name: label, pointMm: cursorMm))
            status = "Landmark saved at MRI crosshair. Verify its physical counterpart before AR registration."
        }
    }

    func removeLandmark(id:String) {
        landmarks.removeAll { $0.id == id }
    }

    func planArchive() throws -> PlanningArchive {
        try PlanningArchive(volume:volume,cursorMm:cursorMm,entryMm:entryMm,
                            targetMm:targetMm,displayedDepthMm:depthMm,
                            landmarks:landmarks,candidates:candidates)
    }

    func importPlan(_ archive: PlanningArchive) throws {
        // Validate FIRST; a mismatching image must not modify an active plan.
        try archive.validate(for:volume)
        cursorMm=archive.cursorMm
        entryMm=archive.entryMm
        targetMm=archive.targetMm
        depthMm=archive.displayedDepthMm
        landmarks=archive.landmarks
        candidates=archive.candidates
        selectedCandidateID=nil
        status="Plan annotations restored against matching MRI voxels. No physical-head registration was restored."
    }

    func report(_ message:String) { status=message }

    func researchARStudy() -> Study? {
        guard landmarks.count >= 3, path.lengthMm > 1e-6,
              (landmarks.map { $0.pointMm }).allSatisfy(\.allFinite) else { return nil }
        let primary=StudyTrajectory(id:UUID().uuidString,name:"Current manually drawn line",entryMm:entryMm,targetMm:targetMm)
        let listed=[primary] + candidates
        return Study(id:UUID().uuidString,
                     title:volume.isSynthetic ? "Synthetic MRI planner" : "Imported MRI · unvalidated head registration",
                     isSynthetic:volume.isSynthetic,landmarks:landmarks,trajectories:listed)
    }

    func saveCandidate() {
        guard path.lengthMm>0 else { status="Set distinct entry and target points first.";return }
        let name="Candidate \(candidates.count+1)"
        let candidate=StudyTrajectory(id:UUID().uuidString,name:name,entryMm:entryMm,targetMm:targetMm)
        candidates.append(candidate)
        selectedCandidateID=candidate.id
        status="Saved \(name) locally for geometric comparison. Not a safe-route recommendation."
    }
    func selectCandidate(id:String) {
        guard let item=candidates.first(where:{$0.id==id}) else { return }
        selectedCandidateID=id
        entryMm=item.entryMm;targetMm=item.targetMm;depthMm=min(depthMm,path.lengthMm)
        cursorMm=item.targetMm
    }
    func deleteSelectedCandidate() {
        guard let id=selectedCandidateID else { return }
        candidates.removeAll(where:{$0.id==id})
        selectedCandidateID=nil
        status="Saved candidate removed from this session."
    }

    var path: StudyTrajectory {
        StudyTrajectory(id:"research-path",name:"Unvalidated research path",entryMm:entryMm,targetMm:targetMm)
    }
    var window: ClosedRange<Float> { lowWindow...max(lowWindow+0.01,highWindow) }
    var maskAnalysis: MaskIntersection? {
        guard let mask else { return nil }
        return TrajectoryMaskSampler.analyze(path,mask:mask,referenceVolume:volume)
    }

    func loadDicomSeries(at urls:[URL]) {
        guard !loading else { return }
        guard urls.count >= 2 else { status="Select at least two DICOM image files from one series.";return }
        loading=true
        status="Importing selected DICOM slices locally…"
        let accessed=urls.map { $0.startAccessingSecurityScopedResource() }
        Task.detached(priority:.userInitiated) { [weak self] in
            let result:Result<VoxelVolume,Error>
            do {
                let files=try urls.map { try Data(contentsOf:$0,options:[.mappedIfSafe]) }
                result = .success(try DicomSeriesReader.load(files:files))
            } catch { result = .failure(error) }
            for (url,opened) in zip(urls,accessed) { if opened { url.stopAccessingSecurityScopedResource() } }
            await MainActor.run {
                guard let self else { return }
                self.loading=false
                switch result {
                case .success(let volume): self.replaceImage(with:volume)
                case .failure(let error): self.status="DICOM import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func replaceImage(with loaded:VoxelVolume) {
        candidates=[];selectedCandidateID=nil;landmarks=[]
        volume=loaded
        mask=nil
        maskIsScalp=false
        maskRevision += 1
        cursorMm=loaded.bounds.center
        entryMm=loaded.bounds.center
        targetMm=loaded.bounds.center
        depthMm=0
        let w=loaded.defaultWindow()
        lowWindow=w.lowerBound
        highWindow=w.upperBound
        volumeRevision += 1
        isoThreshold=Double((w.lowerBound+w.upperBound)*0.5)
        rebuildPreview()
        status="Image loaded in MRI coordinates. Define entry/target manually; it has NOT been registered to a physical head."
    }

    func loadDemoDataset(_ dataset: DemoDataset) {
        guard !loading else { return }
        loading = true
        status = "Downloading and validating \(dataset.title) for offline research preview…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<VoxelVolume, Error>
            do { result = .success(try await DemoDatasetLoader.load(dataset)) }
            catch { result = .failure(error) }
            await MainActor.run {
                guard let self else { return }
                self.loading = false
                switch result {
                case let .success(loaded):
                    self.replaceImage(with: loaded)
                    self.status = "Loaded \(dataset.title) from \(dataset.source). " +
                        "CT and MR are NOT co-registered by this app. Verify individual image orientation."
                case let .failure(error):
                    self.status = "Demo download/import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadVolume(at url: URL, asMask: Bool) {
        guard !loading else { return }
        loading=true
        status="Reading \(asMask ? "segmentation mask" : "CT/MRI volume") locally…"
        let access=url.startAccessingSecurityScopedResource()
        // Security scope must stay active through the actual file read.
        Task.detached(priority:.userInitiated) { [weak self] in
            let result: Result<VoxelVolume,Error>
            do {
                let name = url.lastPathComponent.lowercased()
                guard name.hasSuffix(".nii") || name.hasSuffix(".nii.gz") ||
                      name.hasSuffix(".nrrd") else {
                    throw ImagingError.unsupported("select a .nii, .nii.gz or .nrrd volume")
                }
                let data=try Data(contentsOf:url,options:[.mappedIfSafe])
                let v=try name.hasSuffix(".nrrd") ? NRRDReader.load(data) :
                    CompressedNiftiReader.load(data)
                result = .success(v)
            } catch { result = .failure(error) }
            if access { url.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                guard let self else { return }
                self.loading=false
                switch result {
                case .failure(let error): self.status="Import failed: \(error.localizedDescription)"
                case .success(let loaded):
                    if asMask {
                        guard loaded.dimensions == self.volume.dimensions,
                              self.affineMatches(loaded.affine, self.volume.affine) else {
                            self.status="Mask rejected: require identical voxel grid and physical affine. Resample externally first."
                            return
                        }
                        self.mask=loaded
                        self.maskIsScalp=false
                        self.maskRevision += 1
                        self.rebuildPreview()
                        self.status="ROI segmentation loaded. Overlap is NOT a surgical safety or vessel-clearance measure."
                    } else {
                        self.replaceImage(with:loaded)
                    }
                }
            }
        }
    }

    private func affineMatches(_ a:VoxelAffine,_ b:VoxelAffine)->Bool {
        for (u,v) in zip([a.originMm,a.iMm,a.jMm,a.kMm],[b.originMm,b.iMm,b.jMm,b.kMm]) {
            if (u-v).norm > 0.0001 { return false }
        }
        return true
    }

    func resetDemo() {
        volume=VoxelVolume.syntheticDemo();mask=nil;maskIsScalp=false;maskRevision += 1;cursorMm=Point3(0,0,0)
        candidates=[];selectedCandidateID=nil;landmarks=[]
        entryMm=Point3(30,65,32);targetMm=Point3(5,0,4)
        lowWindow=0;highWindow=200;depthMm=30
        isoThreshold=95
        volumeRevision += 1
        rebuildPreview()
        status="Synthetic demo restored. It is not an MRI or a recommended neurosurgical route."
    }

    /// Builds coarse render-only surfaces from scalar cutoffs. No label or intensity threshold
    /// is treated as a clinically meaningful anatomical segmentation.
    func rebuildPreview() {
        surfaceRequest += 1
        let request=surfaceRequest
        let image=volume
        let roi=mask
        let threshold=Float(isoThreshold)
        tissueSurface=nil
        maskSurface=nil
        surfaceBusy=true
        surfaceStatus="Generating coarse, unvalidated 3D preview…"
        Task.detached(priority:.userInitiated) { [weak self] in
            let tissue=PreviewSurfaceMesher.extract(volume:image,threshold:threshold,
                                                     maxCells:100_000,maxTriangles:50_000)
            let region=roi.map { PreviewSurfaceMesher.extract(volume:$0,threshold:0.5,
                                                              maxCells:100_000,maxTriangles:50_000) }
            await MainActor.run {
                guard let self, self.surfaceRequest == request else { return }
                self.tissueSurface=tissue
                self.maskSurface=region
                self.surfaceBusy=false
                let count=tissue.triangleCount
                let maskCount=region?.triangleCount ?? 0
                let warning=(tissue.truncated || region?.truncated == true) ? " · TRIANGLE LIMIT REACHED (incomplete)" : ""
                self.surfaceStatus="Intensity preview: \(count) triangles; ROI: \(maskCount) triangles; stride \(tissue.samplingStepVoxels) voxel(s)\(warning)"
            }
        }
    }

    func setWindowLow(_ v:Double) { lowWindow=Float(min(v,Double(highWindow)-0.01)) }
    func setWindowHigh(_ v:Double) { highWindow=Float(max(v,Double(lowWindow)+0.01)) }
    func setDepth(_ v:Double) { depthMm=max(0,min(v,path.lengthMm)) }

    func updatePosition(_ point:Point3, type:EditMode?=nil) {
        guard point.allFinite,volume.nearest(at:point) != nil else {
            status="Selected location is outside the imported volume."
            return
        }
        switch type ?? editMode {
        case .cursor: cursorMm=point
        case .entry: entryMm=point; cursorMm=point
        case .target: targetMm=point;cursorMm=point
        }
        depthMm=min(depthMm,path.lengthMm)
        if (type ?? editMode) != .cursor { selectedCandidateID=nil }
    }

    func setAxis(_ axis:Int, value:Double) {
        guard (0..<3).contains(axis) else { return }
        var p:Point3
        switch editMode {
        case .cursor: p=cursorMm
        case .entry: p=entryMm
        case .target: p=targetMm
        }
        p[axis]=value
        updatePosition(p)
    }
}

struct MRIPlanningView: View {
    @ObservedObject var model:MRIPlanningModel
    @ObservedObject var arController:ARHeadController
    let onOpenAR: () -> Void
    @State private var showingDemoLibrary=false
    @State private var importingVolume=false
    @State private var importingMask=false
    @State private var importingDICOM=false
    @State private var importingPlan=false
    @State private var exportingPlan=false
    @State private var exportDocument: ResearchPlanFile?
    @State private var landmarkName = ""
    @State private var arConfirmation=false
    @State private var showAdvanced=false

    private let accent=Color(red:0.22,green:0.84,blue:0.92)

    private var supportedVolumeTypes: [UTType] {
        [UTType(filenameExtension: "nii") ?? .data,
         UTType(filenameExtension: "gz") ?? .data,
         UTType(filenameExtension: "nrrd") ?? .data]
    }

    var body: some View {
        importExportOverlays()
    }

    private var studyScroll: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                header
                importButtons
                Label(model.status, systemImage: model.loading ? "arrow.triangle.2.circlepath" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(NeuroStyle.card, in: RoundedRectangle(cornerRadius: 16))

                HStack(alignment:.top,spacing:12) {
                    metric("IMAGE GRID",model.volume.dimensions.map(String.init).joined(separator:" × "))
                    metric("COORDINATES","R / S / A · mm")
                    metric("SOURCE",model.volume.description)
                }
                Picker("Slice editing",selection:$model.editMode) {
                    ForEach(MRIPlanningModel.EditMode.allCases,id:\.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .tint(accent)

                // Prioritize the axial image for touch precision, then place
                // the other two orthogonal planes side-by-side on iPhone.
                VStack(spacing: 12) {
                    SliceTile(model: model, plane: .axial)
                        .frame(maxWidth: 480)
                    HStack(alignment: .top, spacing: 12) {
                        SliceTile(model: model, plane: .coronal)
                        SliceTile(model: model, plane: .sagittal)
                    }
                }
                Text("Tap a slice to place the selected crosshair, entry, or target. All planes share the same physical millimeter coordinates. Image orientation is research-only and must be verified against source landmarks.")
                    .font(.caption2).foregroundStyle(.secondary)

                trajectoryCard
                depthCard
                intensityProfileCard
                researchLandmarksCard
                planPersistenceCard
                EmbeddedVolumePreview(imaging:model)
                LegacyGeometryControls(model:model)
                candidateCard
                if let analysis=model.maskAnalysis {
                    VStack(alignment:.leading,spacing:6) {
                        Text("SEGMENTATION OVERLAP (UNVALIDATED)").font(.caption.bold())
                        Text("\(analysis.pointsInsideMask) of \(analysis.sampledPoints) sampled path points overlap the ROI mask.")
                        if let d=analysis.firstIntersectionDepthMm {
                            Text(String(format:"First sampled overlap at %.1f mm",d))
                        }
                        if analysis.anyOutOfVolume {
                            Label("Parts of the path are outside the MRI volume",systemImage:"exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Text("A zero-overlap result does not mean a route is safe, collision-free, or anatomically appropriate.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    .padding(12).background(NeuroStyle.card,in:RoundedRectangle(cornerRadius:18))
                }
                DisclosureGroup("Image contrast and coordinates",isExpanded:$showAdvanced) {
                    VStack(spacing:10) {
                        HStack {
                            Text("Window low"); Spacer()
                            Text(String(format:"%.0f",model.lowWindow)).monospacedDigit()
                        }
                        Slider(value:Binding(get:{Double(model.lowWindow)},set:{model.setWindowLow($0)}),
                               in:-2000...4000,step:5).tint(accent)
                        HStack {
                            Text("Window high");Spacer()
                            Text(String(format:"%.0f",model.highWindow)).monospacedDigit()
                        }
                        Slider(value:Binding(get:{Double(model.highWindow)},set:{model.setWindowHigh($0)}),
                               in:-2000...4000,step:5).tint(accent)
                        ForEach(0..<3,id:\.self) { axis in
                            HStack {
                                Text(["X · right","Y · superior","Z · anterior"][axis])
                                Spacer()
                                let selected = selectedPosition
                                Text(String(format:"%.1f mm",selected[axis])).monospacedDigit()
                                Stepper("",value:Binding(get:{selected[axis]},set:{model.setAxis(axis,value:$0)}),
                                        in:(model.volume.bounds.minimum[axis])...(model.volume.bounds.maximum[axis]),
                                        step:1).labelsHidden()
                            }
                        }
                    }.font(.caption).padding(.top,8)
                }.tint(accent)

                Label("RESEARCH / EDUCATION ONLY. Not for patient care, EVD placement, operative planning, or instrument navigation. Registration uncertainty, patient motion, vessels, and image distortion are not validated.", systemImage: "exclamationmark.shield")
                    .font(.caption2.bold()).foregroundStyle(.orange)
                    .padding(12).frame(maxWidth:.infinity,alignment:.leading)
                    .background(Color.orange.opacity(0.09),in:RoundedRectangle(cornerRadius:18))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(NeuroStyle.canvas)
        .onAppear {
            if model.tissueSurface == nil && !model.surfaceBusy { model.rebuildPreview() }
        }
    }

    private func importExportOverlays() -> some View {
        studyScroll
        .sheet(isPresented:$showingDemoLibrary) {
            DemoLibrarySheet { item in
                showingDemoLibrary = false
                model.loadDemoDataset(item)
            }
        }
        .fileImporter(isPresented:$importingVolume,
                      allowedContentTypes:supportedVolumeTypes) { result in
            if case let .success(url)=result { model.loadVolume(at:url,asMask:false) }
        }
        .fileImporter(isPresented:$importingMask,
                      allowedContentTypes:supportedVolumeTypes) { result in
            if case let .success(url)=result { model.loadVolume(at:url,asMask:true) }
        }
        .fileImporter(isPresented:$importingPlan,allowedContentTypes:[.json]) { result in
            do {
                let url=try result.get()
                let access=url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let plan=try JSONDecoder().decode(PlanningArchive.self,from:Data(contentsOf:url))
                try model.importPlan(plan)
            } catch { model.report("Could not import plan: \(error.localizedDescription)") }
        }
        .fileExporter(isPresented:$exportingPlan,document:exportDocument,
                      contentType:.json,defaultFilename:"neuroar-research-plan") { result in
            switch result {
            case .success: model.report("Research plan exported. It contains annotations and a voxel fingerprint, not image pixels; do not treat it as de-identified.")
            case .failure(let error): model.report("Plan export failed: \(error.localizedDescription)")
            }
            exportDocument=nil
        }
        .confirmationDialog("Unvalidated research-only AR overlay",isPresented:$arConfirmation,
                            titleVisibility:.visible) {
            Button("Continue to AR demonstration") {
                guard let study=model.researchARStudy() else { return }
                arController.importPlanningStudy(study:study,
                                                 intensitySurface:model.showIntensity3D ? model.tissueSurface : nil,
                                                 roiSurface:model.showROI3D ? model.maskSurface : nil,
                                                 scalpMaskDesignated:model.maskIsScalp,
                                                 displayedDepthMm:model.depthMm)
                onOpenAR()
            }
        } message: {
            Text("MRI natural-feature annotations must match the facial locations measured by Vision/LiDAR. Face tracking is experimental and does not establish patient identity, target registration accuracy, or suitability for EVD placement.")
        }
        .fileImporter(isPresented:$importingDICOM,
                      allowedContentTypes:[UTType(filenameExtension:"dcm") ?? .data],
                      allowsMultipleSelection:true) { result in
            if case let .success(urls)=result { model.loadDicomSeries(at:urls) }
        }
    }

    private var selectedPosition: Point3 {
        switch model.editMode {
        case .cursor: model.cursorMm
        case .entry: model.entryMm
        case .target: model.targetMm
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(.teal)
                .frame(width: 54, height: 54)
                .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 4) {
                Text("Anatomical study")
                    .font(.title2.weight(.semibold))
                Text("3D MRI · synchronized planes · research paths")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NeuroStyle.card, in: RoundedRectangle(cornerRadius: 22))
    }

    private var importButtons: some View {
        HStack(spacing: 10) {
            Menu {
                Button { importingVolume = true } label: {
                    Label("CT/MRI · NIfTI or NRRD", systemImage: "square.stack")
                }
                Button { importingDICOM = true } label: {
                    Label("DICOM image series", systemImage: "square.on.square")
                }
                Button { importingMask = true } label: {
                    Label("Segmentation ROI mask", systemImage: "square.3.layers.3d")
                }
            } label: {
                Label("Import imaging", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Menu {
                Button { showingDemoLibrary = true } label: {
                    Label("Real CT and MRI demo library", systemImage: "square.stack.3d.up")
                }
                Button { model.resetDemo() } label: {
                    Label("Reset synthetic phantom", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Label("Demos", systemImage: "cube.transparent")
            }
            .buttonStyle(.bordered)
        }
        .disabled(model.loading)
    }

    private var trajectoryCard:some View {
        VStack(alignment:.leading,spacing:9) {
            Text("RESEARCH TRAJECTORY").font(.caption.bold()).tracking(0.8)
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("Entry (orange)").foregroundStyle(.orange)
                    Text(formatPoint(model.entryMm)).font(.caption.monospacedDigit())
                }
                Spacer()
                VStack(alignment:.trailing,spacing:5) {
                    Text("Target (purple)").foregroundStyle(.purple)
                    Text(formatPoint(model.targetMm)).font(.caption.monospacedDigit())
                }
            }
            HStack {
                Text("Geometric path length")
                Spacer()
                Text(String(format:"%.1f mm",model.path.lengthMm))
                    .font(.headline.monospacedDigit()).foregroundStyle(accent)
            }
            if model.volume.isSynthetic {
                Button("Copy demo path into synthetic AR study") {
                    for axis in 0..<3 {
                        arController.setCoordinate(entry:true,axis:axis,value:model.entryMm[axis])
                        arController.setCoordinate(entry:false,axis:axis,value:model.targetMm[axis])
                    }
                    arController.setDepth(model.depthMm)
                }
                .buttonStyle(.bordered)
                .disabled(!arController.study.isSynthetic)
                Text("Only available for the built-in synthetic phantom. Imported MRI coordinates are never silently linked to an AR study.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(NeuroStyle.card,in:RoundedRectangle(cornerRadius:18))
    }

    private var candidateCard:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("SAVED COMPARISON CANDIDATES").font(.caption.bold()).tracking(0.8)
                Spacer()
                Button("Save current path") { model.saveCandidate() }.buttonStyle(.bordered)
            }
            ForEach(model.candidates) { candidate in
                HStack(spacing:10) {
                    Button(candidate.name) { model.selectCandidate(id:candidate.id) }
                        .tint(model.selectedCandidateID==candidate.id ? .cyan : .white)
                    Spacer()
                    Text(String(format:"%.1f mm",candidate.lengthMm)).font(.caption.monospacedDigit())
                    if let mask=model.mask {
                        let result=TrajectoryMaskSampler.analyze(candidate,mask:mask,referenceVolume:model.volume)
                        Text("ROI \(result.pointsInsideMask)/\(result.sampledPoints)")
                            .font(.system(size:10,design:.monospaced)).foregroundStyle(.orange)
                    }
                }
            }
            if model.candidates.isEmpty {
                Text("Save multiple manually drawn lines to compare lengths and sampled ROI intersections. No routes are generated or ranked for safety.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.selectedCandidateID != nil {
                Button("Remove selected candidate",role:.destructive) { model.deleteSelectedCandidate() }
                    .font(.caption)
            }
        }
        .padding(12).background(NeuroStyle.card,in:RoundedRectangle(cornerRadius:18))
    }

    private var intensityProfileCard: some View {
        let samples=PathSampler.sample(model.path,volume:model.volume,mask:model.mask,spacingMm:2.0)
        return VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("MRI INTENSITY ALONG MANUAL LINE").font(.caption.bold()).tracking(0.8)
                Spacer()
                Text("~2 mm samples").font(.caption2.monospaced()).foregroundStyle(.gray)
            }
            PathIntensityGraph(samples:samples,depthMm:model.depthMm)
                .frame(height:126)
                .background(.black.opacity(0.3),in:RoundedRectangle(cornerRadius:8))
            HStack(spacing:12) {
                Label("MRI intensity",systemImage:"waveform.path").foregroundStyle(.cyan)
                Label("ROI overlap samples",systemImage:"circle.fill").foregroundStyle(.orange)
                Label("Depth",systemImage:"line.diagonal").foregroundStyle(.yellow)
            }.font(.system(size:9))
            Text("Sampled signal values and mask overlaps only. Tissue identity, vessel-free clearance, and clinical path safety CANNOT be inferred from this graph.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(NeuroStyle.card,in:RoundedRectangle(cornerRadius:18))
    }

    private var researchLandmarksCard: some View {
        VStack(alignment:.leading,spacing:9) {
            Text("MRI-TO-HEAD RESEARCH LANDMARKS").font(.caption.bold()).tracking(0.8)
            Text("For marker-free tracking, annotate the actual MRI facial anatomy with exact labels: LeftEyeCenter, RightEyeCenter, NoseTip, MouthCenter. All four are recommended; at least three non-collinear visible features must match the camera. Vision detects their physical counterparts automatically; no attached markers or manual camera taps are needed. Appearance and MRI field-of-view matter, and matching is unvalidated.")
                .font(.caption2).foregroundStyle(.secondary)
            Menu {
                ForEach(["LeftEyeCenter", "RightEyeCenter", "NoseTip", "MouthCenter"], id: \.self) { feature in
                    Button { model.addLandmark(name: feature) } label: {
                        Label(feature, systemImage: "mappin.and.ellipse")
                    }
                }
            } label: {
                Label("Tag natural facial feature at crosshair", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text("Choose a named feature to tag its MRI location. Repeating a feature replaces its earlier position. Automatic MRI facial extraction has not yet been validated or implemented.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                TextField("Other feature label",text:$landmarkName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.addLandmark(name:landmarkName.isEmpty ? "Landmark \(model.landmarks.count+1)" : landmarkName)
                    landmarkName=""
                }.buttonStyle(.bordered)
            }.font(.caption)
            ForEach(model.landmarks.indices,id:\.self) { i in
                let landmark=model.landmarks[i]
                HStack(spacing:8) {
                    Text("\(i+1). \(landmark.name)").font(.caption)
                    Spacer()
                    Text(String(format:"%.0f, %.0f, %.0f",landmark.pointMm.x,landmark.pointMm.y,landmark.pointMm.z))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Button(role:.destructive) { model.removeLandmark(id:landmark.id) } label: {
                        Image(systemName:"trash").font(.caption)
                    }
                }
            }
            Button("Transfer this MRI study to live AR") { arConfirmation=true }
                .buttonStyle(.borderedProminent)
                .disabled(model.researchARStudy() == nil || model.loading)
            Text("Transfers MRI coordinates and preview surfaces. The AR camera searches automatically for matching natural facial features and LiDAR depths. No prior registration is reused.")
                .font(.caption2).foregroundStyle(.orange)
        }.padding(12).background(NeuroStyle.card,in:RoundedRectangle(cornerRadius:18))
    }

    private var planPersistenceCard: some View {
        VStack(alignment:.leading,spacing:9) {
            Text("SAVE / RESTORE ANNOTATIONS").font(.caption.bold()).tracking(0.8)
            HStack {
                Button("Export plan JSON") {
                    do {
                        let archive=try model.planArchive()
                        exportDocument=ResearchPlanFile(bytes:try JSONEncoder().encode(archive))
                        exportingPlan=true
                    } catch { model.report("Plan export rejected: \(error.localizedDescription)") }
                }.buttonStyle(.bordered)
                Button("Import plan JSON") { importingPlan=true }.buttonStyle(.bordered)
            }
            Text("The plan contains coordinates, labels, and a voxel fingerprint, but not MRI pixels. It requires identical voxel data and orientation to reopen and never restores AR registration. It is not guaranteed anonymous; do not put patient-identifying labels in it.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(NeuroStyle.card,in:RoundedRectangle(cornerRadius:18))
    }

    private var depthCard:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text("Displayed insertion depth · illustration")
                Spacer()
                Text(String(format:"%.1f / %.1f mm",model.depthMm,model.path.lengthMm))
                    .font(.caption.monospacedDigit()).foregroundStyle(accent)
            }
            Slider(value:Binding(get:{model.depthMm},set:{model.setDepth($0)}),
                   in:0...max(1,model.path.lengthMm),step:0.5)
                .tint(.yellow)
            Text("Yellow marker = depth along the selected line; NOT measured insertion distance in a patient.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func metric(_ name:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text(name).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).lineLimit(2)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private func formatPoint(_ p:Point3)->String {
        String(format:"%.1f, %.1f, %.1f mm",p.x,p.y,p.z)
    }
}

private struct SliceTile: View {
    @ObservedObject var model:MRIPlanningModel
    let plane:ImagingPlane

    var body:some View {
        let raster=model.sliceRaster(for:plane)
        let frame=raster.frame
        VStack(spacing:6) {
            HStack {
                Text(plane.rawValue.uppercased()).font(.system(size:10,weight:.bold,design:.monospaced))
                Spacer()
                Text(String(format:"%.0f mm",model.cursorMm[plane.fixedAxis]))
                    .font(.system(size:10,design:.monospaced)).foregroundStyle(.gray)
            }
            GeometryReader { geometry in
                ZStack {
                    if let image=makeCGImage(raster) {
                        Image(decorative:image,scale:1)
                            .resizable().interpolation(.none)
                    } else { Color.black }
                    // These landmarks are projections. They are NOT necessarily on this slice.
                    Path { path in
                        let c=frame.uv(for:model.cursorMm)
                        let x=c.u*geometry.size.width, y=c.v*geometry.size.height
                        path.move(to:CGPoint(x:x,y:0));path.addLine(to:CGPoint(x:x,y:geometry.size.height))
                        path.move(to:CGPoint(x:0,y:y));path.addLine(to:CGPoint(x:geometry.size.width,y:y))
                    }.stroke(.cyan.opacity(0.65),lineWidth:0.6).allowsHitTesting(false)
                    projectedPath(frame:frame,size:geometry.size)
                    marker(point:model.entryMm,color:.orange,letter:"E",frame:frame,size:geometry.size)
                    marker(point:model.targetMm,color:.purple,letter:"T",frame:frame,size:geometry.size)
                    marker(point:model.path.atDepth(model.depthMm),color:.yellow,letter:"",frame:frame,size:geometry.size)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onEnded { value in
                    let x=min(1,max(0,value.location.x/max(1,geometry.size.width)))
                    let y=min(1,max(0,value.location.y/max(1,geometry.size.height)))
                    model.updatePosition(frame.world(u:x,v:y))
                })
            }
            .aspectRatio(1,contentMode:.fit)
            .clipShape(RoundedRectangle(cornerRadius:6))
            Text(plane == .axial ? "A ↑  ·  R →" : (plane == .coronal ? "S ↑  ·  R →" : "S ↑  ·  A →"))
                .font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(.cyan.opacity(0.8))
            Text("Projected markers · not depth-verified")
                .font(.system(size:8,design:.monospaced)).foregroundStyle(.gray)
        }
        .padding(12).background(NeuroStyle.card,in:RoundedRectangle(cornerRadius:18))
    }

    private func projectedPath(frame:SliceFrame,size:CGSize)->some View {
        let a=frame.uv(for:model.entryMm), b=frame.uv(for:model.targetMm)
        return Path { path in
            path.move(to:CGPoint(x:a.u*size.width,y:a.v*size.height))
            path.addLine(to:CGPoint(x:b.u*size.width,y:b.v*size.height))
        }.stroke(.yellow.opacity(0.8),style:StrokeStyle(lineWidth:1.2,dash:[5,3]))
            .allowsHitTesting(false)
    }

    private func marker(point:Point3,color:Color,letter:String,frame:SliceFrame,size:CGSize)->some View {
        let uv=frame.uv(for:point)
        return ZStack {
            Circle().fill(color).frame(width:9,height:9)
                .overlay(Circle().stroke(.black,lineWidth:1))
            if !letter.isEmpty {
                Text(letter).font(.system(size:9,weight:.heavy,design:.monospaced))
                    .foregroundStyle(color)
                    .offset(x:10,y:-9)
            }
        }
        .position(x:uv.u*size.width,y:uv.v*size.height)
        .allowsHitTesting(false)
    }

    private func makeCGImage(_ raster:SliceRaster)->CGImage? {
        let data=Data(raster.rgba) as CFData
        guard let provider=CGDataProvider(data:data) else { return nil }
        return CGImage(width:raster.width,height:raster.height,bitsPerComponent:8,bitsPerPixel:32,
                       bytesPerRow:raster.width*4,space:CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
    }
}

/// Apple Files document. Import/export is explicitly user initiated; there is
/// no remote upload, background transfer, or network patient-data service.
struct ResearchPlanFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var bytes: Data
    init(bytes:Data) { self.bytes=bytes }
    init(configuration:ReadConfiguration) throws {
        guard let bytes=configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes=bytes
    }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents:bytes)
    }
}

private struct PathIntensityGraph: View {
    let samples:[PathSample]
    let depthMm:Double

    var body: some View {
        GeometryReader { canvas in
            let valid=samples.compactMap(\.intensity).filter(\.isFinite)
            let lower=valid.min() ?? 0
            let upper=max(lower+0.001,valid.max() ?? 1)
            let total=max(0.001,samples.last?.distanceMm ?? 0.001)
            let size=canvas.size
            let rect=CGRect(x:8,y:8,width:max(1,size.width-16),height:max(1,size.height-16))
            ZStack {
                Path { p in
                    var drawing=false
                    for item in samples {
                        guard let v=item.intensity,v.isFinite else { drawing=false;continue }
                        let x=rect.minX+CGFloat(item.distanceMm/total)*rect.width
                        let y=rect.maxY-CGFloat((v-lower)/(upper-lower))*rect.height
                        if !drawing { p.move(to:CGPoint(x:x,y:y));drawing=true }
                        else { p.addLine(to:CGPoint(x:x,y:y)) }
                    }
                }.stroke(.cyan,lineWidth:1.6)
                Path { p in
                    for item in samples where item.insideROI {
                        let x=rect.minX+CGFloat(item.distanceMm/total)*rect.width
                        p.move(to:CGPoint(x:x,y:rect.maxY-4))
                        p.addLine(to:CGPoint(x:x,y:rect.maxY))
                    }
                }.stroke(.orange,lineWidth:2)
                Path { p in
                    let x=rect.minX+CGFloat(min(1,max(0,depthMm/total)))*rect.width
                    p.move(to:CGPoint(x:x,y:rect.minY));p.addLine(to:CGPoint(x:x,y:rect.maxY))
                }.stroke(.yellow.opacity(0.85),style:StrokeStyle(lineWidth:1,dash:[3,3]))
            }
        }
        .accessibilityLabel("Research intensity profile along a manually selected trajectory")
    }
}
