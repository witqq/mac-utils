# App Store submission package

This directory contains the versioned metadata source for Mac Utils. English uses the App Store Connect locale `en-US`; Russian uses `ru`. The public URLs intentionally point to the canonical production host and must be live before submission.

`app-privacy.json` records that the app does not collect data. `age-rating.json` contains questionnaire answers, while the final storefront rating remains assigned by App Store Connect. `review-notes.md` gives App Review a reproducible path through the menu bar app and its two-display feature.

Run `./scripts/check-release-assets.sh` from the repository root before uploading metadata or screenshots.

Current constraints are based on Apple’s App Store Connect reference:

- [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)
- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
