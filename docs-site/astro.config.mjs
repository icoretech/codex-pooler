import { readFile, rm, writeFile } from "node:fs/promises";
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightPageActions from "starlight-page-actions";
import sitemap from "@astrojs/sitemap";
import docsLinks from "./plugins/docs-links.mjs";
import docsImages from "./plugins/docs-images.mjs";
import { renderReleaseVersion } from "./plugins/release-version.mjs";
import { DOCS_REDIRECTS, isIndexablePage } from "./src/legacyRedirects.mjs";

// The landing page is the site root (src/pages/index.astro) and the docs are
// served under /docs (see src/content.config.ts).
const siteOrigin = "https://www.codex-pooler.com";
const siteDescription =
  "Codex Pooler docs for self-hosted Codex account pooling, Pool API keys, backend compatibility, narrow /v1 SDK routes, MCP metadata, routing, and deployment.";

const autogenerateGroup = (label, directory) => ({
  label,
  items: [{ autogenerate: { directory } }],
});

const finalizeMarkdownAssets = () => ({
  name: "codex-pooler-docs-markdown-assets",
  hooks: {
    "astro:build:done": async ({ dir }) => {
      await rm(new URL("_docs-contract.md", dir), { force: true });
      // The page-actions Markdown copy of the 404 page is only its title.
      await rm(new URL("404.md", dir), { force: true });
      // Keep the exported Markdown install command equal to the rendered page.
      const composeGuide = new URL("deployment/docker-compose.md", dir);
      await writeFile(composeGuide, renderReleaseVersion(await readFile(composeGuide, "utf8")));
    },
  },
});

export default defineConfig({
  site: siteOrigin,
  redirects: DOCS_REDIRECTS,
  integrations: [
    // Only canonical content belongs in the sitemap, never legacy redirect stubs.
    sitemap({ filter: isIndexablePage }),
    starlight({
      title: "Codex Pooler",
      description: siteDescription,
      favicon: "/icon.svg",
      head: [
        {
          tag: "link",
          attrs: { rel: "icon", href: "/favicon-32.png", sizes: "32x32", type: "image/png" },
        },
        {
          tag: "link",
          attrs: { rel: "icon", href: "/icon-192.png", sizes: "192x192", type: "image/png" },
        },
        {
          tag: "link",
          attrs: { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
        },
        {
          tag: "meta",
          attrs: {
            name: "robots",
            content: "index,follow,max-snippet:-1,max-image-preview:large,max-video-preview:-1",
          },
        },
        {
          tag: "meta",
          attrs: { name: "author", content: "Codex Pooler maintainers" },
        },
        {
          tag: "link",
          attrs: { rel: "alternate", type: "text/plain", title: "llms.txt", href: "/llms.txt" },
        },
        {
          tag: "link",
          attrs: {
            rel: "alternate",
            type: "text/markdown",
            title: "Codex Pooler answer reference",
            href: "/answers.md",
          },
        },
        {
          tag: "link",
          attrs: {
            rel: "alternate",
            type: "text/markdown",
            title: "Codex Pooler pricing and availability",
            href: "/pricing.md",
          },
        },
        {
          tag: "script",
          attrs: {
            async: true,
            src: "https://analytics.icorete.ch/js/pa-5Klr1c-TW2X9D5KwXBBis.js",
          },
        },
        {
          tag: "script",
          content:
            "window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};plausible.init();",
        },
      ],
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/icoretech/codex-pooler",
        },
        { icon: "x.com", label: "X", href: "https://x.com/icoretech_inc" },
        { icon: "reddit", label: "Reddit", href: "https://reddit.com/r/CodexPooler" },
      ],
      editLink: {
        baseUrl: "https://github.com/icoretech/codex-pooler/edit/main/docs-site/",
      },
      lastUpdated: true,
      pagefind: true,
      disable404Route: true,
      // Titles, social cards and structured data per page (src/routeData.ts).
      routeMiddleware: "./src/routeData.ts",
      components: {
        PageTitle: "./src/components/PageTitle.astro",
        Sidebar: "./src/components/Sidebar.astro",
      },
      plugins: [
        starlightPageActions({
          prompt: "Read {url}. I want to ask questions about it.",
          actions: {
            chatgpt: true,
            claude: true,
            t3chat: true,
            v0: true,
            cursor: true,
            perplexity: true,
            githubCopilot: true,
            markdown: true,
          },
        }),
      ],
      customCss: ["@fontsource-variable/roboto-condensed", "/src/styles/starlight.css"],
      sidebar: [
        {
          label: "Getting Started",
          items: [
            { label: "Overview", slug: "docs" },
            { slug: "docs/getting-started/quick-start" },
            { slug: "docs/getting-started/configuration" },
          ],
        },
        autogenerateGroup("Clients", "clients"),
        autogenerateGroup("Reference", "reference"),
        autogenerateGroup("Operators", "operators"),
        autogenerateGroup("Deployment", "deployment"),
        autogenerateGroup("Monitoring", "monitoring"),
      ],
    }),
    docsLinks({ prefix: "/docs" }),
    docsImages(),
    finalizeMarkdownAssets(),
  ],
});
