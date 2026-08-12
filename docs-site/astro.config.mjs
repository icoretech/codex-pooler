import { rm } from "node:fs/promises";
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightPageActions from "starlight-page-actions";

const siteUrl = "https://docs.codex-pooler.com";
const siteDescription =
  "Codex Pooler docs for a self-hosted gemma3 facade across Ollama, OpenAI, Anthropic Messages, and Codex clients.";

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
      ],
      editLink: {
        baseUrl: "https://github.com/icoretech/codex-pooler/edit/main/docs-site/",
      },
      lastUpdated: true,
      pagefind: true,
      disable404Route: true,
      components: {
        PageTitle: "./src/components/PageTitle.astro",
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
