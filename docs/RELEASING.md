# Release operations

[Русская версия](RELEASING.ru.md)

Mac Utils uses three GitHub Actions workflows. [CI](../.github/workflows/ci.yml) checks every pull request and push to `main`. [GitHub Release](../.github/workflows/release.yml) publishes signed Direct builds from immutable `vMAJOR.MINOR.PATCH` tags. [App Store](../.github/workflows/app-store.yml) is a manual, protected validation/upload path for the same marketing version and build number.

## Protected environments and credentials

GitHub environment secrets are the only credentials read by release jobs. Do not create repository-level copies and never store the decoded files in an artifact, cache, log, commit, or shell history.

The `github-release` environment permits tags matching `v*` plus protected `main` for manual reruns and contains:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`: base64 of the exported Developer ID Application identity and private key;
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`: the export password;
- `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`: base64 of a Team App Store Connect API `.p8` key with the Developer role, scoped operationally to notarization;
- `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_ISSUER_ID`: identifiers for that API key.

The `app-store` environment permits only the protected `main` branch, requires an owner review, and contains:

- `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`: base64 of a separate Team API key with the Admin role required by Xcode cloud-managed distribution signing;
- `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_ISSUER_ID`: identifiers for the Store API key.

Individual API keys cannot authenticate `notarytool`; both environments require Team keys. Keep the Developer-role notarization key and Admin-role Store key separate so the broader cloud-signing permission is unavailable to GitHub Release jobs. Export the Developer ID Application identity from Keychain Access as a password-protected `.p12`, base64-encode it locally, paste the value into the `github-release` environment, and remove the export afterward. GitHub-hosted runners decode credentials only under `RUNNER_TEMP`, import the Direct certificate into a temporary keychain, and delete both at the end of the job. The Store workflow uses its API key with Xcode cloud-managed Apple Distribution and Mac Installer Distribution signing, so no Store certificate or private key is exported.

## Pull-request checks

CI uses macOS 26 with Xcode 26.3 and runs documentation/localization/asset checks, SwiftPM tests, Xcode tests, static analysis, and a full-history Gitleaks scan. Dependencies are cached only in CI; signed release jobs always start from a clean output directory. All third-party actions are pinned to immutable commit SHAs and the default token permission is read-only.

Run the same product checks before opening a pull request:

```sh
./scripts/check-docs.sh
./scripts/check-release-assets.sh
./scripts/test.sh
./scripts/generate-xcode-project.sh
xcodebuild test -project MacUtils.xcodeproj -scheme MacUtils-Direct -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
xcodebuild analyze -project MacUtils.xcodeproj -scheme MacUtils-Direct -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

## Publish a GitHub release

Before tagging, set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, update `CHANGELOG.md`, both release-note languages, metadata, screenshots, and the landing. Merge the green pull request into protected `main`, then create and push the tag from that exact commit:

```sh
git switch main
git pull --ff-only
git tag -a v1.0.0 -m "Mac Utils v1.0.0"
git push origin v1.0.0
```

The release workflow rejects malformed or mismatched versions. It creates a clean universal Direct archive, signs the app and DMG, submits the DMG to Apple notarization, staples and verifies the ticket, calculates SHA-256, and creates GitHub-generated release notes. It publishes `Mac-Utils-v1.0.0.dmg` plus `Mac-Utils-v1.0.0.dmg.sha256`, downloads both back from GitHub, verifies the checksum/signature/ticket/image, and copies the app through the DMG’s `/Applications` layout.

Rerunning the same workflow is safe: open **Actions → GitHub Release → Run workflow** on `main` and enter the existing tag. The workflow takes release automation from protected `main`, but checks out and compiles product sources from that immutable tag after verifying that the tagged commit belongs to `main`. It targets the existing release, replaces only the two versioned assets with newly verified outputs, and does not create a second release. Never move or force-update a published tag. If source changes are required, publish a new patch version.

## Validate or upload the App Store build

Open **Actions → App Store → Run workflow** on `main`, enter the marketing version and build number, and choose `validate` first. Approve the protected `app-store` deployment. The workflow makes a clean App Store archive, exports a signed installer package, validates it with the App Store Connect API key, and retains the package for 14 days. After validation succeeds, rerun the same version/build with `upload` only if that build has not already been uploaded; App Store Connect does not accept duplicate build numbers.

The GitHub release and Store submission for v1.0.0 both use marketing version `1.0.0` and build `1`. A later Store retry that changes executable content must increment `CURRENT_PROJECT_VERSION` and use that new build number everywhere.

## Audit after a run

Confirm that every required job is green, the release has exactly the DMG and checksum, and the Store job reports successful validation or upload. Inspect logs for unexpected command tracing or credential material. GitHub redaction is a fallback, not permission to print a secret. Rotate an API key or certificate immediately if its value appears outside the protected secret store.
