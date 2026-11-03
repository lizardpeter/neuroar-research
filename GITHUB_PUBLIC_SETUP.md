# NeuroAR: GitHub is connected — finish Apple TestFlight setup

**Status (2026-11-03):** The public repository `lizardpeter/neuroar-research` now contains the Swift iOS project, GeometryCore, RustCore, synthetic-only sample data, and GitHub Actions workflows. **You do not need to upload the code again.**

## What is already done

- Public repository on `main`, 33 tracked files.
- `.github/workflows/ios-ci.yml`: macOS Xcode simulator build plus Swift geometry tests.
- `.github/workflows/rust-ci.yml`: Rust unit tests and iPhone/simulator static-library cross-compilation.
- `.github/workflows/testflight.yml`: manually initiated Apple-signed archive and direct TestFlight upload. It does **not** publish the signed IPA to GitHub.
- Privacy-sensitive file extensions are ignored and a basic checked-file scanner runs in CI. **Never commit patient MRI/DICOM or credentials.**

## What the repository owner must configure (Apple credentials cannot be created here)

1. **Apple Developer Program:** Enroll or confirm an active paid membership (TestFlight distribution requires it). <https://developer.apple.com/programs/enroll/>
2. **Apple app identifier:** Choose a unique bundle ID and register it in Apple Certificates, Identifiers & Profiles. The local debug placeholder is `org.neuroar.research.app`; choose a different ID if it is not available. In <https://appstoreconnect.apple.com/> create an iOS app with the *same* ID, version 0.3, and the necessary beta testing information.
3. **Signing and access:** Create an Apple Distribution certificate, export its private key as a password-protected `.p12`, create an App Store provisioning profile for that bundle ID, and create an App Store Connect API key with the necessary App Manager permissions. Download and retain the `.p8` privately. Never paste these keys in chat or commit them.
4. **GitHub protected environment:** Open <https://github.com/lizardpeter/neuroar-research/settings/environments> and create an environment named `testflight`. Restrict deployment branches to `main`. Add reviewer approval if your account/setup supports the reviewer you intend to use. Do not enable 'prevent self-review' when you are the only intended reviewer.
5. **Environment variables:** Under `testflight` add: `APPLE_TEAM_ID`, `APPSTORE_BUNDLE_ID`, `APPSTORE_PROFILE_NAME` (the exact provisioning profile name), `APPSTORE_ISSUER_ID`, `APPSTORE_API_KEY_ID`.
6. **Environment secrets:** Under `testflight` add: `APPSTORE_API_PRIVATE_KEY` (full `.p8` content), `APPSTORE_CERTIFICATES_FILE_BASE64` (base64 of the `.p12`), and `APPSTORE_CERTIFICATES_PASSWORD` (the `.p12` export password). **Only enter these in the GitHub UI.**
7. **Protect `main`:** Configure a ruleset/branch protection and review workflow changes before merging. Ordinary pull requests must never receive signing credentials.
8. **Verify builds:** Inspect <https://github.com/lizardpeter/neuroar-research/actions> and fix any Xcode or Rust cross-compilation problems. Then manually run **Manually publish NeuroAR to TestFlight** on `main`. Approve environment deployment if configured. Once Apple finishes processing, add yourself as an internal tester and install the build wirelessly from the official TestFlight app.

## Security design

- Only the `testflight` job references Apple signing secrets; it runs on `main` and uses a dedicated environment.
- The signed `.ipa` is uploaded **directly to Apple**, not added to GitHub workflow artifacts or releases.
- Public source and the synthetic MRI phantom are safe to publish; real patient imaging data is **never** appropriate in the repository or GitHub Actions.
- Public standard macOS hosted runners are free, but GitHub has separate limits for artifact storage and other services.
- All functionality remains **research/education only**. It is not approved or validated for EVD placement, clinical planning, or patient navigation.

## Swift versus Rust

Use SwiftUI/ARKit/RealityKit for LiDAR access, camera tracking and the iOS experience. Migrate platform-independent imaging/registration/geometry into Rust incrementally, with fixed C ABI functions or an XCFramework after Xcode CI validates the baseline. `RustCore` is currently a small proof-of-cross-compilation and **is not linked into the app yet**.
