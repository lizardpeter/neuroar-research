# NeuroAR Rust core (initial cross-compilation check)

This is the **first** platform-neutral Rust module. It deliberately implements a
small tested numerical primitive rather than replacing the tested Swift
imaging pipeline before we have a successful iOS CI build.

- `cargo test --manifest-path RustCore/Cargo.toml` tests the native crate.
- `cargo build --manifest-path RustCore/Cargo.toml --release --target aarch64-apple-ios` builds a device static library on a Mac with Xcode and the Rust target installed.
- `cargo build --manifest-path RustCore/Cargo.toml --release --target aarch64-apple-ios-sim` builds the arm64 simulator equivalent.
- The stable C ABI is declared in `include/neuroar_core.h`.

**Integration status:** The `.a` library is **not yet linked into the Xcode
target**, and the Swift MRI engine remains authoritative. The CI Rust build
proves cross-compile viability, not finished integration.

Planned division of labor: **SwiftUI / ARKit / RealityKit** for native sensors
and UI; **Rust** for portable MRI decoding, registration, resampling,
segmentation preprocessing, and geometry. Any changes affecting patient
anatomy require independent geometry/coordinate tests. Research only.
