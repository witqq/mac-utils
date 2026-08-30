# Signing and notarization

[Русская версия](SIGNING.ru.md)

Mac Utils has two distribution channels under Apple Developer Team `4U4284E89E`:

- `Release-AppStore` uses App Sandbox and is exported with Cloud Managed Apple Distribution plus the Mac Team Store provisioning profile for `com.witqq.mac-utils`;
- `Release-Direct` uses Hardened Runtime without App Sandbox and is exported with Developer ID Application.

The local Keychain must contain valid Apple Development, Developer ID Application, and Developer ID Installer identities. Xcode may use a cloud-managed Apple Distribution identity for the Store export. Private keys, app-specific passwords, and profiles are never stored in the repository.

Public automation, protected environment names, secret names, versioning, reruns, and Store validation/upload are documented in [Release operations](RELEASING.md). Local Keychain profiles are not copied into CI.

## Local signed archives

Generate a signed archive and distribution export with one of these commands:

```sh
./scripts/archive-xcode-local.sh app-store
./scripts/archive-xcode-local.sh direct
```

The script refuses to overwrite an existing signed artifact. Outputs are under ignored `.build/xcode-archives/` and `.build/xcode-exports/` directories.

Before an App Store upload, validate the archive with `Config/ExportOptions/AppStoreValidate.plist`. Validation requires an App Store Connect app whose bundle ID is `com.witqq.mac-utils`.

## Direct app and DMG

Use `Config/ExportOptions/DeveloperIDNotarize.plist` with `xcodebuild -exportArchive` and destination `upload` to send the Developer ID archive through the Xcode account. After Apple accepts it, export the stapled application with `xcodebuild -exportNotarizedApp`.

Create the disk image from that application and sign the container itself:

```sh
./scripts/create-dmg.sh \
  "/path/to/Mac Utils.app" \
  "/path/to/Mac-Utils-v1.0.0.dmg" \
  "Developer ID Application"
```

The image contains `Mac Utils.app`, an `/Applications` link, the versioned background, and a deterministic Finder layout. Submit and staple it with the Keychain profile:

```sh
./scripts/notarize-dmg.sh "/path/to/Mac-Utils-v1.0.0.dmg" mac-utils-notary
```

The notarization script verifies the container signature, Apple ticket, Gatekeeper assessment, disk-image integrity, and final SHA-256 checksum. The checksum is calculated after stapling because stapling changes the image bytes.

## Credential handling

Store notarization credentials interactively so the app-specific password never appears in shell history or repository files:

```sh
xcrun notarytool store-credentials mac-utils-notary
```

Use Xcode **Settings → Accounts → Manage Certificates…** to create or renew certificates. Re-run `security find-identity -v -p basic`, a signed archive/export, and the relevant Gatekeeper checks after renewal. Do not replace a missing release identity with ad-hoc signing.
