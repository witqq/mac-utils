# Brand assets

The production AppIcon and menu bar template icon are deterministic SVG-derived assets. Regenerate their PNG variants with `./scripts/generate-brand-assets.sh`.

`backgrounds/ambient-displays.png` was generated with OpenAI ImageGen on 2026-08-30 as an abstract raster foundation. Its prompt was:

> Use case: ambient visual foundation for a polished macOS utility landing page, GitHub social preview, and optional DMG background. Asset type: wide abstract background artwork, no text. Create a premium minimal scene suggesting two display planes and a universal state toggle through two floating rounded rectangular glass panels connected by one smooth luminous transition arc. Style: refined soft 3D, matte translucent glass, restrained depth, subtle macOS-like precision without imitating any Apple UI or product. Composition: wide landscape, strong calm negative space in the center-left for later code-rendered typography, visual interest concentrated toward the right and outer edges, safe crop at 16:9 and 2:1. Palette: deep graphite and near-black base, electric blue and cyan accents, a very faint violet glow, high-end but understated. Lighting: soft controlled bloom, crisp panel edges, no grain. Constraints: no words, no letters, no numbers, no logos, no Apple marks, no devices with identifiable branding, no interface screenshots, no icons, no watermark, no border.

All typography, product marks, screenshots, social previews, and DMG composition are rendered from versioned source and real application captures by `./scripts/compose-marketing-assets.sh` and `./scripts/capture-screenshots.sh`.
