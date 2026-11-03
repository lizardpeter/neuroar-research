# RustCore native iOS link

NeuroAR is a **hybrid Swift + Rust** application. `scripts/build-rust-ios.sh` is
run by an Xcode prebuild phase and compiles a native Rust static library for
`iphoneos` or `iphonesimulator`, including per-architecture compilation and
`lipo` when Xcode requests multiple simulator architectures. The app links the
result via `-lneuroar_core`; `NeuroAR/RustBridge.swift` calls its exported C ABI.

Currently the visible trajectory length display uses `neuroar_distance_mm`.
This is a real Swift-to-Rust call, not just a standalone Rust CI compilation.
Other medical-image and registration math remains in tested Swift
`GeometryCore` until separately migrated and validated.

Developer requirements: Xcode/Apple SDK and `rustup`/`cargo` with the iOS
cross-compile targets. GitHub macOS CI installs Rust before compiling the app.
The production TestFlight archive workflow does the same. No private Rust
binary artifact is checked into the public repository. All results are
research demonstration only, not medical-device performance guarantees.
