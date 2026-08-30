# App Store submission package

This directory contains the versioned metadata source for Mac Utils. English uses the App Store Connect locale `en-US`; Russian uses `ru`. The public URLs intentionally point to the canonical production host and must be live before submission.

`app-privacy.json` records that the app does not collect data. `age-rating.json` is the Fastlane-compatible source for the App Store Connect age-rating declaration. `review-notes.md` gives App Review a reproducible path through the menu bar app and its two-display feature.

The protected [App Store Metadata workflow](../.github/workflows/app-store-metadata.yml) synchronizes the localized metadata, screenshots, copyright, price, worldwide availability, categories, age rating, review contact, release mode, and selected build. Apple does not expose the app privacy questionnaire through the App Store Connect API, so the initial **No, we do not collect data from this app** answer and its publication remain a one-time App Store Connect web step. Keep `app-privacy.json` and the published answer aligned whenever functionality changes. The account holder must also make the legally required Digital Services Act trader/non-trader self-assessment in App Store Connect; release automation must not choose that legal status.

Run `./scripts/check-release-assets.sh` from the repository root before uploading metadata or screenshots.

Current constraints are based on Apple’s App Store Connect reference:

- [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)
- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
