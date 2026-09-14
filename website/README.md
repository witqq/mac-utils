# Landing maintenance

`website/` is the source for `https://mac-utils.witqq.dev/`. The page is authored declaratively for
[agentic-report](https://agentic-report.witqq.dev/) and built into a committed static directory:

- `source/report.md` — English entry with layout, theme, tokens, and metadata;
- `source/report.ru.md` — Russian variant with the same structure; the built page picks the initial
  language from the browser and offers a language selector;
- `source/assets/` — local captures (`builder-*.webp`, `shortcuts-*.webp`), `app-icon.png`, `og-image.png`;
- `source/fixtures/` — screenshot-fixture configurations used to capture the landing screenshots;
- `dist/` — generated output served by nginx. Never edit it by hand.

Rebuild after any change to `source/`:

```sh
./scripts/build-landing.sh
./scripts/check-release-assets.sh
```

`build-landing.sh` runs the pinned `agentic-report@0.14.0` release with `--format directory`, refuses a
build with warnings, copies the unhashed icon and social preview into `dist/assets/`, and injects the
canonical URL, favicon, theme color, and Open Graph tags that the generator does not own.

To refresh the captures, build the Direct Debug app, then run it with `--screenshot-fixture
--configuration-file website/source/fixtures/landing-<en|ru>.json --settings-tab <scripts|shortcuts>
--capture-ui <png>` and convert the PNG with `cwebp -q 82`; the Shortcuts capture is cropped to its top
760 pixels.

Whenever the shipped feature set or a user-facing workflow changes, update the landing in the same product
change: keep both language variants equivalent, regenerate captures when the affected interface is visible
on the landing, update the feature, help, privacy, support, and App Store metadata claims that are
affected, and do not advertise a capability before its implementation and verification are part of the
release. The App Store call to action stays a plain “coming soon” note until a real product URL exists.

## Deployment

The canonical deployment is the stateless `mac-utils` Compose project on server `witqq.ru`, remote
directory `/opt/mac-utils`, public host `https://mac-utils.witqq.dev`. Nginx serves only `website/dist/`
from a read-only unprivileged container; runtime data and persistent volumes are not used. The nginx
Content-Security-Policy allows scripts only from the site itself and inline style declarations, which the
agentic-report runtime requires.

Before deploying, run the landing in the real container: nginx configuration errors cannot be caught by
the static checks, and a broken directive stops the container from starting at all.

```sh
docker build -f deploy/Dockerfile -t mac-utils-site-local .
docker run -d --rm --name mac-utils-site-smoke -p 3040:4080 mac-utils-site-local
curl -sI http://127.0.0.1:3040/ | grep -i content-security-policy
curl -s http://127.0.0.1:3040/ | shasum -a 256    # must equal website/dist/index.html
docker rm -f mac-utils-site-smoke
```

Port 3040 is reserved for this smoke container in the local port inventory. A regex `location` block with
braces must stay quoted, otherwise nginx reads the braces as a configuration block and refuses to start.

Validate and deploy from the repository root:

```sh
./scripts/check-release-assets.sh
infra-tools config .deploy-config.json
infra-tools auto --server witqq.ru --config .deploy-config.json
infra-tools status mac-utils --server witqq.ru --remote-dir /opt/mac-utils
```

After every landing or product-link change, verify trusted TLS, `/health`, both languages, desktop and
mobile layout, the GitHub repository and DMG downloads, and that the served `index.html` matches the
committed `dist/index.html`.
