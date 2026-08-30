# Landing maintenance

`website/` is the source for `https://mac-utils.witqq.dev/`. It has no external runtime dependencies and must remain usable in English and Russian.

Whenever the shipped feature set or a user-facing workflow changes, update the landing in the same product change:

- keep both `data-en` and `data-ru` copy accurate and equivalent;
- regenerate real localized UI captures with `./scripts/capture-screenshots.sh` when the affected interface is visible on the landing;
- update the feature, help, privacy, support, and App Store metadata claims that are affected;
- run `./scripts/check-release-assets.sh` and visually check desktop and mobile layouts;
- do not advertise a capability before its implementation and verification are part of the release.

The App Store call to action remains disabled until a real product URL exists. GitHub and DMG destinations must follow the published repository and release naming.
