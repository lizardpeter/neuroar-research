# NeuroAR: GitHub Actions → TestFlight → wireless iPhone install

The workflows in `.github/workflows/` are **templates** until the project is
committed to a GitHub repository and its Apple Developer signing is configured.
They have not been run on a hosted Mac or uploaded to App Store Connect.

## Prerequisites (one-time)

1. Enroll in the **paid Apple Developer Program**. Register an explicit iOS App ID
   and create an app record with that same bundle identifier in App Store Connect.
2. Create an **Apple Distribution** signing certificate, export it **with its private
   key** as password-protected `.p12`, and make an App Store distribution
   provisioning profile whose name corresponds to the bundle ID.
3. Generate an **App Store Connect API** key with sufficient app-upload rights.
   Store the `.p8` contents only as a GitHub Actions secret.
4. Push this project to a **public GitHub repository**, after reviewing it for patient data and secrets. Create a protected `testflight` environment restricted to `main`. See [`GITHUB_PUBLIC_SETUP.md`](GITHUB_PUBLIC_SETUP.md).

## GitHub Actions Variables

Repository → Settings → Environments → **testflight** → **Environment variables**:

| Variable | Meaning |
| --- | --- |
| `APPLE_TEAM_ID` | 10-character Apple Developer team ID |
| `APPSTORE_BUNDLE_ID` | Explicit app bundle ID, matching App Store Connect and the profile |
| `APPSTORE_PROFILE_NAME` | Exact App Store distribution provisioning profile name |
| `APPSTORE_ISSUER_ID` | App Store Connect API issuer UUID |
| `APPSTORE_API_KEY_ID` | App Store Connect API key ID |

## GitHub Actions Secrets

Repository → Settings → Environments → **testflight** → **Environment secrets**:

| Secret | Meaning |
| --- | --- |
| `APPSTORE_API_PRIVATE_KEY` | Entire text of downloaded `AuthKey_*.p8` |
| `APPSTORE_CERTIFICATES_FILE_BASE64` | Base64 of distribution `.p12` containing the private key |
| `APPSTORE_CERTIFICATES_PASSWORD` | Export password of that `.p12` |

**Never paste credentials into code, chat, issue comments, or Git commits.**

## Building and wirelessly installing

1. Push to `main`, open GitHub **Actions** → `iOS simulator build and geometry
   tests`, and check that both Swift package tests and the unsigned simulator
   compile succeed. This is not a real-device/LiDAR test.
2. Open **Actions** → `Manually publish NeuroAR to TestFlight` → **Run workflow**.
   The macOS runner imports the signing certificate, downloads the provisioning
   profile, archives a device `.ipa`, and uploads to TestFlight.
3. Wait for Apple to process the build in App Store Connect. Add the signed-in
   Apple Account as an **internal TestFlight tester**, or arrange external testing
   (the first external build requires Beta App Review). For internal testers,
   set up a TestFlight group; automatic build distribution is optional.
4. On the iPhone, install **TestFlight** from the App Store, accept the invitation
   and tap **Install**. Future accepted builds can be updated wirelessly.

No USB cable or local Mac is needed for this *release/testing* path. The iPhone
must be compatible with the required iOS version; live LiDAR requires LiDAR
hardware. ARKit behavior and medical image geometry must still be validated on
a real device and independent synthetic phantoms.

## Scope and safety

Do not commit patient scans, identifiable medical images, case IDs, or secrets.
The example synthetic `.nii` is explicitly excluded from `.gitignore`; no other
`.nii` or `.dcm` files belong in the repository. The TestFlight workflow does not publish signed build artifacts or signing logs. The simulator CI workflow may upload an unsigned build log on failure. The app's import pipeline operates locally.

This app is **research/education only** and is not appropriate for EVD insertion,
patient-specific trajectory guidance, or care decisions. The 3D threshold
preview is not validated tissue segmentation.
