# NeuroAR TestFlight — automatic cloud signing (no local Xcode)

The live deployment workflow is [`.github/workflows/testflight.yml`](.github/workflows/testflight.yml). It uses Apple's `xcodebuild -allowProvisioningUpdates` and cloud-managed distribution signing. **No local Xcode installation, USB cable, manual CSR, exported .p12, or manually created provisioning profile is required for the automatic-signing attempt.**

## Already configured by the repository owner

The GitHub `testflight` environment has already been created and restricted to `main`, with:

- Secret `APPSTORE_API_PRIVATE_KEY`: the full Team API `.p8` key
- Variable `APPSTORE_API_KEY_ID`: the API Key ID
- Variable `APPSTORE_ISSUER_ID`: the Issuer ID

Do not paste the key into an issue, commit, chat, or workflow YAML.

## Finding the Apple Developer Team ID

Open https://developer.apple.com/account/ (not the App Store Connect Users and Access page), then select **Membership details** on the account landing page. Apple lists your 10-character **Team ID** there alongside your membership information. This is **not** the App Store Connect API Key ID or Issuer ID. Add it as a GitHub `testflight` environment **variable** called `APPLE_TEAM_ID` (not a secret). If Membership details is absent, check whether the purchase has fully activated and the signed-in account is the Account Holder. Apple's help: https://developer.apple.com/help/glossary/team-id/

## Remaining Apple setup — no Mac needed

1. **Add the Apple Team ID.** In [Apple Developer account](https://developer.apple.com/account/), find your **10-character Team ID** (Membership details). In [GitHub testflight environment](https://github.com/lizardpeter/neuroar-research/settings/environments), add **Environment variable** `APPLE_TEAM_ID` (not a secret). Do not substitute the API Issuer ID.
2. **Register the explicit App ID and App Store Connect app record**, if not already created:
   - [Apple Developer identifiers](https://developer.apple.com/account/resources/identifiers/list): register the iOS App ID `com.pg.neuroar.research`.
   - [App Store Connect Apps](https://appstoreconnect.apple.com/): create **NeuroAR Research** using that same bundle ID (the app can remain unreleased). The first build cannot be uploaded without an app record.
   - If you chose a different bundle ID in Apple, set GitHub **Environment variable** `APPSTORE_BUNDLE_ID` to your exact identifier. Otherwise the workflow defaults to `com.pg.neuroar.research`.
3. Open [GitHub Actions / TestFlight](https://github.com/lizardpeter/neuroar-research/actions/workflows/testflight.yml), choose **Run workflow** on `main`, and approve the environment deployment if GitHub asks.
4. Once Apple finishes processing, set up an **internal TestFlight group** in App Store Connect and add yourself (your Apple Account needs an appropriate team role). Install using Apple's TestFlight iPhone app.

## How it works

1. A protected, manually dispatched GitHub Actions job on a hosted macOS runner loads the Team API key **only from the environment secret**, into a mode-600 temporary file.
2. A read-only API preflight checks that the correct App Store Connect app record exists. This does not upload credentials or patient data.
3. The runner tests Rust and Swift, creates an **unsigned archive** with the configured bundle and Team IDs, then attempts an **automatic cloud-signing export**.
4. The export uses `destination=upload` to send the signed result **directly to Apple**. There is no public GitHub IPA artifact.
5. Temporary private-key material is deleted in an `always()` cleanup step; the runner is ephemeral.

## Important limitations

- **Cloud-signing rights are account-dependent.** An **App Manager** Team API key might be able to upload but not have cloud-managed certificate/provisioning privileges. Apple says Account Holder/Admin have cloud signing by default; other roles may need the specific cloud-signing permission. **We have not tested the account's entitlement.** If Apple's export reports permission failures, review the key permissions and account/team certificate access. Prefer a narrowly authorized identity; do not create an Admin key until an explicit, verified permission blocker requires it.
- An unsigned archive exported through cloud signing is a supported CI pattern but this particular application's workflow **has not yet been verified end-to-end**. If `xcodebuild -exportArchive` rejects the unsigned archive, the fallback requires a signing identity or a revised archive strategy; the workflow must report failure rather than publishing an invalid IPA.
- This workflow does **not** automatically enroll in the Apple Developer Program, register an App ID, create an App Store Connect app record, or manage internal tester invitations.
- Signed IPA archives, private keys, patient scans, and health data must never be committed or uploaded as public GitHub artifacts.
- Protect `main`, restrict environment deployment to `main`, approve releases, and review workflow changes. The App Store Connect Team API key may have broad team-wide privileges.
- The app is research/education only, not a validated EVD placement or surgical guidance system.

## Legacy configuration

The previous manual-signing workflow required `APPSTORE_CERTIFICATES_FILE_BASE64`, `APPSTORE_CERTIFICATES_PASSWORD`, and `APPSTORE_PROFILE_NAME`. **Those values are no longer referenced** by the automatic-signing workflow. You do not need to generate them unless Apple's cloud-signing attempt proves unavailable.

Apple reference: https://developer.apple.com/videos/play/wwdc2021/10204/
