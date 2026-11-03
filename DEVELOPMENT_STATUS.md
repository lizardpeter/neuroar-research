# NeuroAR research prototype — implementation and validation status

**Educational and software-research use only. Not for EVD insertion, neurosurgical planning, patient care, or instrument navigation.** An attractive overlay and low landmark-fit residual do not establish intracranial accuracy.

## Implemented source (as of v0.5 development milestone)

- Import uncompressed `.nii` MRI with explicit sform/qform orientation, and simple uncompressed conventional 2-D DICOM image series. Unsupported enhanced/compressed/ambiguous DICOM series are rejected rather than guessed.
- Linked axial/coronal/sagittal MRI views, intensity windowing, crosshair, manual line entry/target selection and displayed depth in MRI millimeters.
- Locally imported same-grid NIfTI binary ROI masks, 3D coarse intensity/ROI triangle previews and a sampled MRI-intensity/ROI-overlap profile along the manual line.
- Multiple manually drawn comparison candidates and named MRI landmarks, with an explicit MRI-to-AR handoff.
- A portable versioned JSON planning annotation format, with strict voxel/grid identity check before importing; no image pixels in the exported plan. **An exported annotation plan is not guaranteed to be de-identified:** names, geometry and the scan-derived fingerprint can be sensitive.
- LiDAR sceneDepth capture with a bounded 3×3 confidence-filtered median neighborhood for corresponding physical landmarks, rigid registration with fit residual display and an optional final held-out *surface* landmark residual, and AR view of manual line and *coarse, explicitly unvalidated* surfaces. Re-linking an image clears prior AR registration. No head-motion correction or automatic MRI registration is implemented.
- GitHub Actions for Swift tests/iOS Simulator, Rust static library cross-compilation and a protected, manually triggered signed TestFlight upload. Never publish signed IPAs as public GitHub artifacts.

## Current limitations

- No automatic segmentation of the skull, vessels, ventricles, or other anatomy; an intensity isosurface is **not** a tissue segmentation.
- No clinical image registration, reliable target registration error (TRE), dynamic physical-head tracking, optical fiducial accuracy, distortion correction, calibration protocol, or instrument tracking.
- No automatic or clinically vetted EVD entry selection, target selection, safe-path recommendations, or risk scores. ROI overlap counts and MRI-intensity profiles are *descriptive, not safety classifiers*.
- Input support is intentionally narrow: no compressed `.nii.gz`, JPEG/JPEG2000/RLE compressed DICOM, enhanced multiframe MRI, DICOM-SEG, multi-label color-coded segmentations or diffusion tractography yet.
- 3D previews are clipped to bounded triangle budgets and can be incomplete. They should not be used for clearance measurements.
- Until macOS CI and LiDAR device testing are independently verified, iOS source changes should be regarded as unverified on real hardware.

## Next development milestones

1. Obtain successful Xcode iOS Simulator builds and run physical-device LiDAR/AR usability tests, with a synthetic physical phantom.
2. Add importers for clinically common compressed formats and independent image-orientation cross checks.
3. Add named, independently generated masks/segmentation surfaces for distinct structures; track provenance and uncertainty.
4. Develop a phantom-based registration protocol with known physical fiducials, repeated position/orientation testing, held-out target errors, and motion-loss fail-safe behavior.
5. Introduce reproducible, instrumented memory/performance tests for large MRI data and 3D surfaces.
6. Connect the Rust computational core via a reproducible universal static-library / XCFramework build once the iOS baseline is stable.
7. Complete distribution through Apple's official private TestFlight process after membership activation.

## Privacy and deployment

Do not commit patient scans, DICOM headers, medical identifiers, device pairing records, Apple keys or distribution certificates. Keep Apple credentials in a protected GitHub `testflight` environment and review any changes to CI workflows before release.
