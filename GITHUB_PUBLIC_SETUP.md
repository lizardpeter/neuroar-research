# NeuroAR public GitHub + private TestFlight setup

**Scope:** public source, unsigned simulator builds, manually gated Apple signing, direct TestFlight upload. No signed IPA/archive published to GitHub Actions artifacts or Releases. This remains unvalidated research-only software, not for clinical navigation or treatment.

## What the repository owner does

1. At <https://github.com/new>, create **`neuroar-research`** as a **Public** repository. Leave **Add a README**, `.gitignore`, and **license** unchecked; they are included or should be chosen deliberately later. Use `main` as the default branch. Upload/push the project contents preserving `.github/workflows/` (see commands below).
2. On GitHub open **Settings → Environments → New environment → `testflight`**. Set **Deployment branches and tags → Selected branches and tags → `main`**. If available, add required reviewers (not yourself alone if GitHub prohibits self-approval). The workflow independently checks `refs/heads/main`.
3. Set **Settings → Branches / Rulesets** to protect `main` (at least require review for workflow changes when collaborators are added). Avoid accepting unreviewed third-party workflow changes. Keep **Actions → General → Workflow permissions** at read-only by default.
4. In [Apple Developer](https://developer.apple.com/programs/enroll/) confirm that your team belongs to the **paid Apple Developer Program**; TestFlight distribution cannot run with free Personal Team provisioning.
5. Register an explicit App ID / bundle identifier in Apple's Certificates, Identifiers & Profiles, and create an app with the *exact same* bundle ID at [App Store Connect](https://appstoreconnect.apple.com/). Provide TestFlight test information (beta description, feedback email, primary language), accept required agreements, and configure the intended internal tester.
6. Set up an Apple Distribution certificate (`.p12` containing its private key) and App Store Connect API key (`.p8`); Apple-Actions provides [setup guidance](https://github.com/Apple-Actions/download-provisioning-profiles) for generating signing assets. **Do not share credentials in chat, repository issues, commits, or files.**
7. Put **all** signing values into the `testflight` **environment** (not general repository secrets) under **Settings → Environments → testflight**:

   | Variables | Description |
   | --- | --- |
   | `APPLE_TEAM_ID` | Apple Developer Team ID |
   | `APPSTORE_BUNDLE_ID` | Exact registered iOS bundle identifier |
   | `APPSTORE_PROFILE_NAME` | Exact matching App Store provisioning profile name |
   | `APPSTORE_ISSUER_ID` | App Store Connect API issuer ID |
   | `APPSTORE_API_KEY_ID` | App Store Connect API key ID |

   | Secrets | Description |
   | --- | --- |
   | `APPSTORE_API_PRIVATE_KEY` | Complete downloaded `.p8` key text |
   | `APPSTORE_CERTIFICATES_FILE_BASE64` | Base64-encoded Apple Distribution `.p12` with private key |
   | `APPSTORE_CERTIFICATES_PASSWORD` | Password used to export `.p12` |

   This scoping keeps signing secrets out of ordinary PR CI jobs. Do not expose them in any step output or build script.
8. Wait for **iOS simulator build and geometry tests** on `main` to pass. This is the first actual Apple toolchain compile, and may uncover issues not detected by Swift tests on Linux. Only then choose **Actions → Manually publish NeuroAR to TestFlight → Run workflow** with branch `main`. Approve the protected environment if required. The workflow uploads directly to Apple without publishing a signed IPA to GitHub.
9. Open TestFlight on your iPhone and accept the internal tester invitation from App Store Connect. Beta processing can require additional app information; internal testing avoids external Beta App Review. No cable or your own Mac is required for this distribution path.

## Upload the local project to the empty repository

Extract the provided zip. In a terminal **inside the `NeuroAR-Research` directory**, run:

```bash
git init
git branch -M main
git add .
bash scripts/check-public-repo.sh
git commit -m "Initialize NeuroAR research iOS application"
git remote add origin https://github.com/YOUR_GITHUB_USERNAME/neuroar-research.git
git push -u origin main
```

The public repo must contain source and the synthetic demonstration dataset only. No patient-derived scans, patient metadata, credentials, or proprietary assets. This script is a **basic filename guard**, not a substitute for reviewing the entire commit history and code.

## Important security notes

- Never put real patient data in Git or Actions. Clinical DICOM must remain outside this public toolchain.
- Any collaborator able to change the `main` workflow can potentially alter code executed in a privileged signing job. Keep that branch and the `testflight` environment protected, and review changes before a release.
- Environment approval is a human gate, not a sandbox. Only run reviewed code from `main`.
- No IPA, `.xcarchive`, `.p12`, private `.p8`, profiles, or signing logs should be stored as GitHub artifacts.
- Do not run fork PR code with signing secrets or use `pull_request_target` for untrusted code.
- Public repository standard hosted runners have no compute-minute billing, but storage and other GitHub services can have separate limits.
- Native iOS build and LiDAR function are still **unverified** until GitHub Actions compiles the target and it is tested on a real compatible iPhone.
