# NeuroAR Research — MRI visualization + head-tracking experiments

**Research and educational software only. NOT for EVD insertion, image-guided
surgery, clinical trajectory selection, patient care, or instrument navigation.**
No diagnostic or registration accuracy certification is claimed.

This open-source native iOS prototype combines **SwiftUI / ARKit / RealityKit**
with a **natively linked Rust static library**, and a cross-platform Swift
`GeometryCore`. Source: https://github.com/lizardpeter/neuroar-research

## Current capabilities (v0.9 natural-head research prototype)

- **MRI import:** NIfTI-1 `.nii` and gzip-compressed `.nii.gz`, with bounded
  decompression, GZIP checksum validation, original affine, spacing and intensity
  scaling. Imports matching-grid NIfTI masks. Non-scalar, NIfTI-2, ambiguous
  orientation and unvalidated dimensions are rejected.
- **DICOM import:** conventional single-frame monochrome 8/16-bit Part 10 MR
  slices with consistent geometry; native Explicit/Implicit VR Little Endian,
  and **RLE Lossless encapsulated** pixel data. Mixed series, wrong frame
  dimensions/spacing, irregular slice positions and unsupported transfer
  syntaxes are rejected. **JPEG/JPEG-LS/JPEG 2000, enhanced multiframe,
  deflated DICOM and mosaics are still unsupported.**
- **Planning workspace:** synchronized axial/coronal/sagittal MRI slices,
  volume windowing, matching-grid imported ROI, user-defined lines/entry/target,
  depth slider, 3D intensity and mask previews, sampled intensity/ROI profile,
  multiple saved candidates, manually labelled image landmarks, and annotation
  import/export validated against a scan fingerprint.
- **AR workspace (marker-free):** The rear camera detects natural facial features
  using Apple Vision, samples those features with high-confidence LiDAR depth,
  and matches them to explicitly annotated MRI anatomical features by name.
  No printed marker, face sticker, or attached fiducial is required. The
  estimate updates while a single face remains visible, and the MRI overlay
  hides or resets on ambiguity, excessive motion, inadequate depth, or ARKit
  tracking loss. **These are unvalidated, coarse feature correspondences, not
  automatic MRI feature extraction or independent anatomical accuracy.**
- **Optional surface refinement:** User-designated external scalp mask may
  provide samples for a landmark-seeded, trimmed ICP refinement. Fitted ICP
  residual is **not TRE**.
- **On-device diagnostic capture:** LiDAR high-confidence sampled point cloud
  summary against an acknowledged nonhuman phantom. Reports point count and
  3D cloud spread, **not** accuracy. Does not upload raw point clouds or images.
- **Rust linked into iOS:** `RustCore` exports the path distance C ABI, called
  by the Swift UI. Its static library is built from source during Xcode builds
  for the requested Apple architecture. Other compute kernels remain in Swift.

## Run and build

1. `swift test --package-path GeometryCore` runs image, format, geometry,
   registration, and synthetic-phantom tests on macOS or Linux with zlib.
2. For iPhone/macOS: open `NeuroARResearch.xcodeproj` with Xcode. Install stable
   Rust (`rustup`, `cargo`) and the target for your device/simulator; Xcode
   invokes `scripts/build-rust-ios.sh` as a prebuild script. The iPhone must
   support ARKit LiDAR to capture scene depth.
3. For compressed NIfTI, import `.nii.gz` directly from Files. For DICOM,
   select consecutive `.dcm` images from the same series. If a format is
   unsupported, use a medically validated external converter and verify
   orientation and spacing before visualizing.
4. Load a mask only when its grid and affine match. A random intensity
   isosurface is **not** an anatomically validated scalp or vessel mask.
5. For natural head tracking without any attached fiducials, see
   [`docs/NATURAL_HEAD_TRACKING.md`](docs/NATURAL_HEAD_TRACKING.md).
   Create MRI facial labels (`LeftEyeCenter`, `RightEyeCenter`, `NoseTip`,
   `MouthCenter`) before the transfer. Independently test with a phantom,
   including head motion, occlusion, tracker reset and loss of LiDAR depth.
6. Public GitHub Actions runs macOS iOS Simulator builds; a separately
   triggered workflow signs and uploads directly to **private TestFlight**
   once Apple account credentials are configured. See
   [`TESTFLIGHT_SETUP.md`](TESTFLIGHT_SETUP.md).

## Validation and limitations

`docs/ACCURACY_AND_TESTING.md` describes physical-device phantom protocols,
registration quality, motion-failure checks and the distinction between
fitted surface error and independently measured target registration error.

**Not yet implemented/validated:** robust JPEG-LS/JPEG2000 or enhanced DICOM;
validated MRI scalp/vascular/ventricular segmentation; fully automatic
identification of facial anatomy *within MRI*; independently accurate
marker-free MRI-to-head registration or full-head 360-degree tracking;
independent clinically relevant TRE; calibration correction; on-device LiDAR
measurements; clinical device approval. No candidate route is ranked for
anatomical safety or EVD suitability.

Do not put patient MRIs, identifiers, Apple private keys, provisioning data,
or signed IPAs in a public repository. TestFlight secrets belong in a GitHub
protected environment restricted to the main release branch.
