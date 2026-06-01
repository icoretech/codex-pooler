import { rm } from "node:fs/promises";
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightPageActions from "starlight-page-actions";

const siteUrl = "https://docs.codex-pooler.com";
const siteDescription =
  "Codex Pooler docs for self-hosted Codex account pooling, Pool API keys, backend compatibility, narrow /v1 SDK routes, MCP metadata, routing, and deployment.";

const softwareStructuredData = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Codex Pooler",
  applicationCategory: "DeveloperApplication",
  applicationSubCategory: "AI developer tooling",
  operatingSystem: "Docker Compose and Kubernetes",
  url: `${siteUrl}/`,
  description: siteDescription,
  softwareRequirements: "Docker Compose or Kubernetes for self-hosted deployments",
  softwareHelp: {
    "@type": "CreativeWork",
    url: `${siteUrl}/`,
  },
};

const autogenerateGroup = (label, directory) => ({
  label,
  items: [{ autogenerate: { directory } }],
});

const removePrivateMarkdownAssets = () => ({
  name: "codex-pooler-docs-private-markdown-filter",
  hooks: {
    "astro:build:done": async ({ dir }) => {
      await rm(new URL("_docs-contract.md", dir), { force: true });
    },
  },
});

export default defineConfig({
  site: siteUrl,
  redirects: {
    "/reference/endpoint-routing/": "/reference/runtime-routes/",
  },
  integrations: [
    starlight({
      title: "Codex Pooler",
      description: siteDescription,
      head: [
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
          attrs: { type: "application/ld+json" },
          content: JSON.stringify(softwareStructuredData),
        },
      ],
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/icoretech/codex-pooler",
        },
      ],
      editLink: {
        baseUrl: "https://github.com/icoretech/codex-pooler/edit/main/docs-site/",
      },
      lastUpdated: true,
      pagefind: true,
      components: {
        PageTitle: "./src/components/PageTitle.astro",
      },
      plugins: [
        starlightPageActions({
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
      customCss: ["/src/styles/starlight.css"],
      sidebar: [
        {
          label: "Getting Started",
          items: [
            { slug: "getting-started/quick-start" },
            { slug: "getting-started/configuration" },
          ],
        },
        autogenerateGroup("Clients", "clients"),
        autogenerateGroup("Reference", "reference"),
        autogenerateGroup("Operators", "operators"),
        autogenerateGroup("Deployment", "deployment"),
      ],
    }),
    removePrivateMarkdownAssets(),
  ],
});
