# Codex Pooler website

The public website at [www.codex-pooler.com](https://www.codex-pooler.com), in one [Astro](https://astro.build) project: the landing page at the site root and the documentation, built with [Starlight](https://starlight.astro.build), under `/docs`.

## Develop

```sh
npm ci
npm run dev      # http://localhost:4321/ and http://localhost:4321/docs/
```

From the repository root, `make dev` also reinstalls this project's locked dependencies before starting Phoenix. Use `make dev-docs-deps` to refresh only the website dependencies; it does not start or build the website.

## Check and build

```sh
npm run check    # astro check, website regression tests and docs contract checks
npm run build    # static site in dist/
npm run check:seo # audit every built page, sitemap, canonical and internal link
npm run preview  # serve the build locally
```

## Layout

| Path | What |
| --- | --- |
| `src/pages/index.astro` | The landing page, assembled from `src/landing/components/` |
| `src/landing/` | Landing page components, layout, styles, data and images |
| `src/content/docs/` | Documentation pages. `src/content.config.ts` gives their ids a `docs/` prefix, so they are served under `/docs` without living in a `docs/` folder |
| `plugins/docs-links.mjs` | Adds `/docs` to root-relative page links in the docs, so pages keep linking with paths like `/operators/pools/` |
| `plugins/docs-images.mjs` | Gives docs images from `public/` their width and height, loads a page's first image eagerly with high priority and the rest lazily |
| `src/routeData.ts` | Starlight route middleware: page titles without a doubled brand, the social card tags, and a TechArticle with breadcrumbs per docs page |
| `src/og/`, `src/pages/og/` | Build-time social cards, one 1200x630 JPEG per docs page at `/og/<page id>.jpg`, with the text drawn as paths from the Roboto Condensed files in `src/og/fonts/` |
| `public/` | Files served at the site root: images (the docs banners are 1440px WebP copies of the README banners), `llms.txt`, `answers.md`, `pricing.md`, `robots.txt`, the landing page's social card `og.jpg`, the monitoring dashboards, and the landing page's logos and icons |
| `scripts/`, `dashboards/` | Checks run by `npm run check`, and the dashboard build |

Known documentation links from before the move under `/docs` get a static redirect page from `src/pages/[...legacy].astro`. The paths come from the docs collection, and renamed guides point directly to their final address. GitHub Pages serves these as HTTP 200 pages with an immediate HTML refresh, a canonical destination and a fallback link; they do not depend on JavaScript or return a 404. Unknown paths keep the site-wide 404 page (`src/content/docs/404.mdx`). Permanent HTTP redirects at the hosting edge remain preferable when available.

The post-build SEO check verifies sitemap coverage, canonical URLs, index/noindex separation, unique titles and descriptions, headings, image alt attributes, social-card files, structured data and internal links and anchors. It runs before the Pages artifact can be uploaded. It checks the generated site; live redirects, edge filtering, Google indexing and real-user Core Web Vitals require separate production checks.

The landing page carries one structured-data graph (Organization, WebSite, SoftwareApplication) that every docs page points at by `@id`. The docs use the same variable Roboto Condensed WOFF2 files as the landing page, from `@fontsource-variable/roboto-condensed`.

The project explicitly uses Astro's `scopedStyleStrategy: "where"` to preserve low-specificity component styles and class-based scope propagation across the landing page and docs. Starlight respects this setting rather than forcing its own strategy; keep it explicit so a dependency update cannot silently switch the site to higher-specificity attribute scopes. The custom sidebar still reveals the current page on a fresh visit and when the mobile menu opens, and the page actions stay outside the search index.

## Social card rendering

Docs social cards are rendered at build time by `src/og/card.ts`: the bundled Roboto Condensed 400 and 700 TTF files supply the glyph outlines, and sharp rasterizes the complete SVG into a 1200×630 JPEG. The renderer does not depend on system fonts or Pango.

`opentype.js` remains pinned to 1.3.4. The published 2.0.0 release applies a `ccmp` composition lookup that requires GSUB chaining contextual substitution type 6, format 2, which it cannot execute. Both bundled fonts throw `substitutionType : 62 lookupType: 6 - substFormat: 2 is not yet supported` even when measuring `CODEX POOLER`; passing `features: { ccmp: false }` does not disable that lookup. The publisher also deprecated 1.3.5 as an accidental publication of 2.0.0, so it is not a compatible v1 update. Removing font lookup tables or bypassing word shaping is not a safe upgrade.

The dependency update remains pending until a published release can execute these fonts' class-based chaining substitutions correctly. Before upgrading, verify glyph selection, advance widths, wrapping and SVG path placement with both weights; font changes or exception fallbacks must not hide an incompatibility.

TypeScript stays on the newest 6.x release while `@astrojs/check` requires the TypeScript JavaScript API and accepts only `^5.0.0 || ^6.0.0`. The Grafana Foundation SDK uses its stable `latest` release, pinned to `0.0.22`; the older `11-6-latest` channel is not the update target. Lock-file maintenance refreshes compatible transitive dependencies without overriding consumers' exact version or major-version constraints.

## Landing page

`src/pages/index.astro` assembles the sections from `src/landing/components/`:

| Section | Component | Notes |
| --- | --- | --- |
| Nav | `Nav.astro` | Sticky, with a mobile menu |
| Hero | `Hero.astro` | Live routing console: client requests pass the Key, Pool, Eligible and Route checks inside a Pool and land on the account with the most quota left, with a request log underneath. Same quota model as the simulator: no spontaneous refills, only saved resets |
| Logo strip | `LogoStrip.astro` | Marquee of supported tools, each linking to its setup guide |
| How it works | `Simulator.astro` | "Flip the switch": the same four tools and four accounts without and with Pooler, with an LED status badge. With Pooler the gateway holds two Pools (Product team, Automation), each serving its own tools from its own accounts. Bars show quota left and only drain (faster on smaller plans); an empty account comes back to 100% only when a saved reset is spent. Mirrors the product rules: a Pool spends a saved reset only once all its accounts are dry, one at a time, waiting for confirmation before another; an expiring reset on an account with some usage is spent in its last hour. Without Pooler, Account C's saved reset counts down and expires unused. OpenAI occasionally banks a new saved reset |
| Pools | `Pools.astro` | Three example Pools with their own accounts, keys and rules, one account shared between two |
| Just one account? | `OneAccount.astro` | Five agents signed in with one Codex login next to the same agents holding Pool keys: a copy of the login asks to sign in again, key counts climb, one key pauses without touching the rest. Linked from the FAQ |
| Guardrails | `Guardrails.astro` | Example requests walk the checks in the order Pooler applies them (firewall, key, Pool switches, model, request size, token windows); a request that fails a check stops there with the documented status and code |
| OpenAI-compatible | `Compat.astro` | Codex subscriptions in tools without Codex support: a generic settings example and buttons to every tool's setup guide |
| Features | `Features.astro` | Bento: keys, Observatory, MCP, saved resets, Stats and request log, alerts |
| Everything else | `AllFeatures.astro` | Grouped list of the remaining features, each backed by the docs |
| Dashboard | `Dashboard.astro` | Eight tabs of dark-theme admin captures in a browser frame whose URL follows the tab |
| Get started | `GetStarted.astro` | Three steps and a terminal with Docker Compose and Helm tabs, both pinned to the latest stable release |
| Trust | `Trust.astro` | Self-hosting, secrets, privacy, license, and what Pooler is not |
| FAQ | `Faq.astro` | Native `<details>` accordion |
| Final CTA and footer | `FinalCta.astro`, `Footer.astro` | |

Every link into the docs goes through `docs()` in `src/landing/data/site.ts`, which points at `/docs`. The supported tools and their guide links live in the same file.

All motion respects `prefers-reduced-motion`, and the animations pause when their section is off screen or the tab is hidden.

The release shown in the hero and pinned in the Compose instructions comes from `.release-please-manifest.json`, and the chart version pinned in the Helm instructions comes from the Helm deployment guide, which Renovate keeps on the latest chart. Both change only through commits, so the landing page always matches the docs. The GitHub star count is read from the GitHub API at build time and left out when the API can't be reached; the Pages workflow passes `GITHUB_TOKEN` to avoid the anonymous rate limit.

### Writing rules

The page makes public claims about the product, so keep them measured and checkable against the docs:

- Describe `/v1` support as OpenAI-compatible for the requests coding tools need, never as full OpenAI API parity.
- Never suggest that Pooler gets around OpenAI's limits or terms.
- The license is the Elastic License 2.0: say "source available" or "free to self-host", not "open source".
- Keep examples generic: `codex-pooler.example.com`, "Account A", "Nightly agent". No real account, Pool, install or person names.
- Pools are plural: the point is splitting accounts and traffic into as many Pools as you need, so never sell Pooler as "one pool".
- Quota bars always show what is left and drain. In the animations they return to full only when a saved reset is spent; don't show accounts resetting on their own.
- Don't single out one tool: name tools only as examples among several.
- No "demo data" or "illustration" disclaimers on product visuals; the captures come from deterministic fixtures, not from anyone's traffic.
- Privacy is a fact to state once, not the headline. Traffic can leave through the operator's own HTTP proxy, so never claim requests go "straight" to OpenAI.

### Assets

| Path | Source |
| --- | --- |
| `src/landing/assets/pooler.webp` | The mascot, from `.github/assets/pooler.png` (used in the closing call to action) |
| `src/landing/assets/screens/*.webp` | Dark-theme admin captures (1440×900 at 2×) taken from the deterministic screenshot fixtures, converted to WebP. Retake them when the admin UI changes |
| `public/logos/*.svg` | Normalized monochrome marks from `priv/static/images/client-logos/`, with provenance in `assets/client-logos/manifest.json` and the upstream licenses next to it |
| `public/icon.svg` | The mascot's face, drawn for small sizes: the site icon for every page |
| `public/og.jpg` | 1200×630 social preview |

Product names and logos belong to their owners. OpenAI and Codex are trademarks of OpenAI; Codex Pooler is not affiliated with OpenAI.

## Deploy

Pushes to `main` that touch `docs-site/` or `.release-please-manifest.json` run `.github/workflows/pages.yml`, which checks, builds and publishes `dist/` to GitHub Pages. The custom domain `www.codex-pooler.com` is set in the repository's **Settings → Pages**.
