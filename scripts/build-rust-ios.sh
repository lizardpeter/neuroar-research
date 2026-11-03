#!/usr/bin/env bash
# Invoked by Xcode BEFORE Swift source compilation. A fresh native Rust static
# library is produced for every requested architecture and linked into the app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
command -v rustup >/dev/null || { echo 'rustup is required to build NeuroAR RustCore' >&2; exit 1; }
command -v cargo >/dev/null || { echo 'cargo is required to build NeuroAR RustCore' >&2; exit 1; }
PLATFORM="${PLATFORM_NAME:-iphonesimulator}"
case "$PLATFORM" in
  iphoneos) default_arch="arm64" ;;
  iphonesimulator) default_arch="arm64" ;;
  *) echo "Unsupported Apple platform: $PLATFORM" >&2; exit 1;;
esac
ARCH_LIST="${ARCHS:-$default_arch}"
OUT="$ROOT/.build/rust/$PLATFORM"
mkdir -p "$OUT"
libs=()
for arch in $ARCH_LIST; do
  case "$PLATFORM:$arch" in
    iphoneos:arm64) triple=aarch64-apple-ios ;;
    iphonesimulator:arm64) triple=aarch64-apple-ios-sim ;;
    iphonesimulator:x86_64) triple=x86_64-apple-ios ;;
    *) echo "Unsupported Rust build architecture: $PLATFORM:$arch" >&2; exit 1;;
  esac
  rustup target add "$triple" >/dev/null
  cargo build --manifest-path "$ROOT/RustCore/Cargo.toml" --target "$triple" --release --locked
  artifact="$ROOT/RustCore/target/$triple/release/libneuroar_core.a"
  test -s "$artifact"
  libs+=("$artifact")
done
if (( ${#libs[@]} == 1 )); then
  cp "${libs[0]}" "$OUT/libneuroar_core.a"
else
  xcrun lipo -create "${libs[@]}" -output "$OUT/libneuroar_core.a"
fi
# Detect misconfigured platform/ARCHS or unexpectedly empty linker inputs.
test -s "$OUT/libneuroar_core.a"
echo "Built native RustCore for $PLATFORM: $ARCH_LIST"
