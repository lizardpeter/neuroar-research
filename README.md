# NeuroAR Research — native iOS imaging and AR prototype

**Educational and software-research use only. NOT for patient care, EVD placement, clinical trajectory planning, surgery, or instrument navigation.** No accuracy or medical-device validation is claimed.

## What's in this version

### 3-D MRI visualization and GitHub → TestFlight pipeline (v0.3)
- SceneKit now places three **actual resampled, textured MRI slice planes** in the study's physical coordinate system. The section planes move with the common crosshair and include the existing externally supplied ROI overlay.
- New **coarse marching-tetrahedra isosurfaces** show a user-controlled image-intensity cutoff and a separately imported, matching-grid binary ROI mask. The intensity cutoff DOES NOT segment the brain, skull, ventricles, vessels, or any specific tissue; a mask's accuracy depends entirely on its source.
- Iso-surfaces are generated off the UI thread with a bounded sampling resolution and maximum triangle count, and flagged if incomplete. They show approximate geometry only and are not appropriate for distance-to-vessel or implant-clearance measurements.
- Three render toggles: MRI planes / scalar intensity surface / imported ROI surface. The trajectory, tip marker, and saved candidates remain in the same model-space frame.
- Added a shared Xcode scheme, `ios-ci.yml` for macOS-runner simulator compilation and geometry tests, and **manually triggered** `testflight.yml` for signed IPA upload to TestFlight after Apple Developer setup. Setup steps for a public repository are in [`GITHUB_PUBLIC_SETUP.md`](GITHUB_PUBLIC_SETUP.md) and the detailed [`TESTFLIGHT_SETUP.md`](TESTFLIGHT_SETUP.md). These workflows have NOT run yet.
- No connection between actual imported MRI volumes and live AR is implied. The AR view remains an unvalidated synthetic-only demonstration until image-to-physical registration is independently verified.

### Native imaging planner
- Native SwiftUI MRI workspace with **synchronized axial, coronal, and sagittal** views. Tap any plane to update the crosshair, path entry, or target, in real-world image coordinates (millimeters).
- **NIfTI-1 `.nii` 3-D volume reader**, little-/big-endian, scalar unsigned/signed integer and floating formats; honors `sform` or `qform` affine and spatial units. `.nii.gz`, NIfTI-2, RGB, 4-D time series, and unsupported/missing orientations are rejected explicitly.
- **Conventional DICOM series importer**: select multiple `.dcm` Part-10 files belonging to one MR series. Supports uncompressed Explicit/Implicit VR Little Endian, single-frame MONOCHROME2 8-/16-bit grayscale, physical slice positions and orientations, pixel spacing and value scaling. Rejects JPEG/deflated, Enhanced multiframe, compressed, irregular/gapped, mixed, mosaic/unsupported image data rather than silently misaligning it. Not a complete DICOM implementation.
- Physical-coordinate trilinear sampling and adjustable grayscale window; optional **binary ROI mask** import as matching-grid `.nii` with cyan overlay. Masks must have identical grid size and affine; independently preprocess/validate any third-party segmentations.
- On-image R/S/A labels. **This view's rightward direction is +R, not standard radiological left-on-screen convention.** Always audit imported orientation against recognizable anatomy.
- Research trajectory selection: manually set entry and target in MRI space, inspect projected paths, calculate line length and slider-controlled displayed depth, save candidates within the session, compare sampled intersections against a supplied ROI mask.
- Orbitable SceneKit **3D MRI section overview** displays three orthogonal intensity slices, optional intensity-cutoff surface and optional external binary-ROI surface, plus line/markers. None represents verified skull/brain tissue, a safe route, or a validated segmentation.
- Offline synthetic `.nii` example in `examples/synthetic-phantom.nii` plus synthetic demo mode.

### AR prototype (carried forward)
- Native ARKit rear-camera tracking, RealityKit overlay, LiDAR `sceneDepth` landmark sampling, manually paired external facial landmark registration (Horn rigid fit), optionally imported USDZ mesh, path line and displayed depth.
- Imported MRI/DICOM volumes are **not automatically associated with physical landmarks, studies, or USDZ meshes**. Only the built-in synthetic phantom exposes an explicit demonstration path-copy action between planner and AR.
- Registration is discarded on AR session exit/tracking loss. No continuous patient-head motion tracker, independent target-registration error, or calibration confidence bounds are available.
- No uploaded files are sent to servers in this implementation.

## Run the app

1. On macOS, open `NeuroARResearch.xcodeproj` with Xcode 16 or newer; use iOS 18+ and choose your own developer team / bundle ID.
2. Start on the **MRI PLANNER** tab. The default is synthetic anatomy. Tap **MRI .nii** and select `examples/synthetic-phantom.nii` if you want to test file import, or choose a 3-D anatomical `.nii` file with a valid qform/sform.
3. For DICOM, choose **DICOM .dcm** and multi-select *all consecutive conventional slices* from **one** series. If the importer rejects the format, convert using a validated converter such as dcm2niix, verify orientation, then import `.nii`. Do not force files to load by deleting orientation metadata.
4. Tap **Crosshair**, **Entry**, or **Target**, then tap positions on any of the three orthogonal slices. Adjust displayed path depth. Tap **Save current path** to compare candidates. Import a **matching-grid, pre-segmented ROI .nii** to show sampled path/ROI intersections.
5. For the AR synthetic experiment, switch to **LIVE AR** on a LiDAR-capable iPhone Pro or supported iPad Pro. Use only a *stationary synthetic head phantom* with calibrated landmarks, not a person. Matching imported patient MRI with live AR is not implemented.

## Source organization

- `GeometryCore/Sources/GeometryCore/GeometryCore.swift`: rigid landmark registration, study and trajectory models
- `GeometryCore/Sources/GeometryCore/MedicalImaging.swift`: voxel affine, trilinear sampling, linked view geometry, ROI intersection
- `GeometryCore/Sources/GeometryCore/NiftiReader.swift`: NIfTI-1 parser with explicit RAS-to-canonical axis conversion
- `GeometryCore/Sources/GeometryCore/DicomSeriesReader.swift`: narrow conventional DICOM slice-series reader with explicit LPS-to-canonical axis conversion
- `GeometryCore/Sources/GeometryCore/SurfaceMesher.swift`: bounded research-only marching-tetrahedra surface preview, values in millimeters
- `GeometryCore/Tests/GeometryCoreTests`: independent synthetic fixtures and numerical/format tests (15 automated tests)
- `NeuroAR/MRIPlanningView.swift`: native 3-plane viewer, study import, candidate editing
- `NeuroAR/TrajectorySceneView.swift`: orbitable real MRI section textures, iso-surface preview, ROI preview, bounding-box/path geometry
- `NeuroAR/ARHeadController.swift` / `DepthUnprojector.swift`: AR registration, LiDAR point capture and RealityKit visualization

## Coordinates and units

NeuroAR's *internal canonical frame* is **X=right, Y=superior, Z=anterior**, in millimeters. This is neither typical DICOM LPS nor NIfTI RAS axis order. NIfTI RAS `(R,A,S)` is mapped to `(R,S,A)`; DICOM LPS `(L,P,S)` maps to `(-L,S,-P)`. All transforms must remain in millimeters until converted to ARKit world meters. Unit and affine handling are tested, not clinically validated. Rotating/cropping/segmenting image data externally requires preserving/recomputing its affine.

The legacy study JSON uses the same canonical frame. USDZ import requires preconverted mesh coordinates in **meters** in that frame. There is no enforced MRI-study-USDZ identity check beyond the synthetic demonstration boundary; do not use those overlays with patient data.

## Run tests

```bash
cd GeometryCore
swift test
```

Tested on Linux Swift 6 with fixture-based registration, NIfTI sform/qform/big-endian, DICOM explicit/implicit little-endian, voxel sampling, slice coordinate projection, and geometric ROI sampling.

The iOS source is **Swift syntax parsed**, but **this environment has no Xcode or iOS SDK**. The iOS app has **not** been compiled on iOS or verified with an iPhone. Xcode compile/runtime corrections may be needed.

## Technical / clinical limitations

- Imported segmentation is an externally prepared **unvalidated binary ROI mask**, not automatic ventricle, vascular, or skull segmentation. A zero-intersection result **does not prove safety**. No automatically proposed or ranked EVD trajectories.
- SceneKit 3D now renders physical **orthogonal MRI sections** and **coarse intensity isosurfaces**; it is NOT full GPU ray-marched volume rendering or validated tissue segmentation. LiDAR head surface reconstruction/ICP, clinical-grade 3D tissue segmentation and full 3D volume ray-marching remain future milestones.
- DICOM support is intentionally limited. A scanner-specific DICOM series, de-identified image, NIfTI affine, or image orientation may still be wrong. Visual and independent geometric validation is required.
- No brain-shift modeling, head-motion compensation, real-time patient tracking, optical fiducials, calibration acceptance testing, or measured target registration error (TRE). ARKit tracking the *phone* is not tracking the patient's skull.
- Landmark residual RMSE shown in AR is a *fit statistic*, never an intracranial accuracy estimate. The 15-mm registration guard in the demo is **not a medical tolerance**.
- Real-world clinical use would require independent phantoms/ground truth, robust registration, device and software hazard analysis, human-factors testing, regulatory evaluation, and specialist oversight.

### Next development milestones

1. Validated label-map metadata and independently reviewed skull/scalp/ventricle/vessel segmentation (3D generic threshold preview exists, but not anatomical segmentation or verified MRI tissue rendering).
2. Secure image-study-to-physical-head identity association, immutable audit trail, rigid surface registration and independently quantified TRE/uncertainty.
3. Head tracking with continuous drift detection and fail-closed AR overlay, validated through independent phantom experiments.
4. Dedicated comparison workspace and exportable research reports, subject to privacy safeguards and validation.

## CI and no-cable iPhone installation

The GitHub Actions workflows are now **committed to the public repository**. Follow `GITHUB_PUBLIC_SETUP.md` and `TESTFLIGHT_SETUP.md` to create an Apple Developer app, signing identity, provisioning profile, API key, and GitHub variables/secrets. Ordinary pushes build on a hosted Mac against iOS Simulator without signing. A manually triggered workflow can sign and upload a release to App Store Connect/TestFlight. After TestFlight processing and an invitation, installation on the iPhone works over the air. **Neither a Mac runner execution nor a TestFlight installation has been verified for this package.** Do not upload patient images or secrets to GitHub.


## Swift + Rust architecture (next step)

The first cross-platform Rust static library is in `RustCore/` with a C ABI, a native unit-test suite, and a separate macOS/iOS cross-compilation workflow. **It is not yet linked into the iOS application**; Swift remains the tested MRI imaging implementation. Native ARKit/LiDAR/SwiftUI will remain in Swift while MRI decoding, geometry, and registration may be migrated to Rust incrementally after CI passes. See `RustCore/README.md`.
