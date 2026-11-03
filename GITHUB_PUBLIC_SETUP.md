# NeuroAR — current GitHub and Apple deployment setup

**Status (2026-11-03):** The public repository contains the native Swift/ARKit application, Rust and Swift validation suites, and public-source CI. A protected manually triggered TestFlight workflow has been updated to attempt **Apple automatic cloud signing** using the App Store Connect Team API key already stored in the GitHub `testflight` environment.

**No local Xcode, USB cable, private distribution certificate export, or .p12 provisioning setup is required for the primary cloud-signing attempt.**

Follow the current [TestFlight setup guide](TESTFLIGHT_SETUP.md) rather than the older manual certificate instructions.

## Existing secure environment

- GitHub environment: `testflight`, restricted to branch `main`
- Environment secret: `APPSTORE_API_PRIVATE_KEY` (full private `.p8` key)
- Environment variables: `APPSTORE_API_KEY_ID`, `APPSTORE_ISSUER_ID`
- Team ID environment variable: `APPLE_TEAM_ID` **still required** (10 characters)
- Bundle ID environment variable: `APPSTORE_BUNDLE_ID` **optional** if using default `com.lizardpeter.neuroar.research`

A matching **registered Apple App ID and App Store Connect app record** must exist before upload. The workflow checks the app record via a read-only Apple API request. You can create the app record from a browser; Apple does not currently expose an ordinary App Store Connect REST endpoint to create app records.

The TestFlight workflow signs using Apple's cloud service if permitted by your team/API key; no signing material is uploaded as a public GitHub artifact. A Team API key with the App Manager role may lack cloud signing privileges, so actual Apple signing must be verified before calling this fully deployed.

## Security

Only dispatch from `main` after reviewing workflow changes; protect the branch and keep approvals enabled if available. Never commit credentials or patient medical images. The GitHub runner receives the API key from the encrypted environment secret, writes it to a private temporary file, and deletes it in an always-run cleanup. The temporary runner is ephemeral. Third-party actions in the credentialed workflow are pinned to GitHub commit SHAs.

## Developer architecture

SwiftUI/ARKit/RealityKit retain the native UI, camera, LiDAR and iOS lifecycle. RustCore and GeometryCore provide cross-platform compute components. The project remains a research and education prototype, not validated clinical EVD guidance.

[GitHub Actions](https://github.com/lizardpeter/neuroar-research/actions) · [TestFlight release workflow](https://github.com/lizardpeter/neuroar-research/actions/workflows/testflight.yml) · [TestFlight setup](TESTFLIGHT_SETUP.md)
