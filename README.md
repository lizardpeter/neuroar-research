# NeuroAR Research — MRI visualization + head-tracking experiments

**Research and educational software only. NOT for EVD insertion, image-guided
surgery, clinical trajectory selection, patient care, or instrument navigation.**
No diagnostic or registration accuracy certification is claimed.

This open-source native iOS prototype combines **SwiftUI / ARKit / RealityKit**
with a **natively linked Rust static library**, and a cross-platform Swift
`GeometryCore`. Source: https://github.com/lizardpeter/neuroar-research

## Current capabilities (v0.8 development)

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
- **AR workspace:** LiDAR depth-based manually paired landmarks and rigid
  registration with reserved held-out landmark check, camera tracking-state
  loss handling, MRI-to-AR handoff, and an *optional* landmark-seeded, trimmed ICP
  surface refinement. ICP requires an explicitly designated external scalp mask
  and 4+ physical landmarks; its surface fit residual is **not TRE**.
- **Moving phantom:** ARKit detects the supplied 50 mm high-contrast marker.
  After manual registration the app can bind the MRI overlay relative to the
  image anchor. It updates as the marker moves and automatically hides the
  overlay when tracking is lost. This is **research marker tracking**, not
  markerless continuous patient tracking or validated head tracking.
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
5. For head tracking, see [`docs/HEAD_MARKER.md`](docs/HEAD_MARKER.md).
   Use a synthetic phantom, measure its independent landmarks, and confirm
   no overlay remains visible when the 50 mm marker is lost.
6. Public GitHub Actions runs macOS iOS Simulator builds; a separately
   triggered workflow signs and uploads directly to **private TestFlight**
   once Apple account credentials are configured. See
   [`TESTFLIGHT_SETUP.md`](TESTFLIGHT_SETUP.md).

## Validation and limitations

`docs/ACCURACY_AND_TESTING.md` describes physical-device phantom protocols,
registration quality, motion-failure checks and the distinction between
fitted surface error and independently measured target registration error.

**Not yet implemented/validated:** robust JPEG-LS/JPEG2000 or enhanced DICOM;
validated MRI scalp/vascular/ventricular segmentation; fully markerless
MRI-to-head registration; independent clinically relevant TRE; calibration
correction; patient motion tracking without a marker; on-device LiDAR
measurements; clinical device approval. No candidate route is ranked for
anatomical safety or EVD suitability.

Do not put patient MRIs, identifiers, Apple private keys, provisioning data,
or signed IPAs in a public repository. TestFlight secrets belong in a GitHub
protected environment restricted to the main release branch.
