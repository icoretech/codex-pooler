import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightPageActions from "starlight-page-actions";

const autogenerateGroup = (label, directory) => ({
  label,
  items: [{ autogenerate: { directory } }],
});

export default defineConfig({
  site: "https://docs.codex-pooler.com",
  integrations: [
    starlight({
      title: "Codex Pooler",
      description: "Public documentation for Codex Pooler operators and client integrators.",
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
  ],
});
