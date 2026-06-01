/// <reference types="astro/client" />

interface PageAction {
  label: string;
  href: string;
}

interface PageActionsConfig {
  prompt?: string;
  actions?: {
    chatgpt?: boolean;
    claude?: boolean;
    t3chat?: boolean;
    v0?: boolean;
    cursor?: boolean;
    perplexity?: boolean;
    githubCopilot?: boolean;
    markdown?: boolean;
    custom?: Record<string, PageAction>;
  };
  share?: boolean;
  locales?: Record<
    string,
    {
      prompt?: string;
      actions?: {
        custom?: Record<string, Partial<PageAction>>;
      };
    }
  >;
}

declare module "virtual:config" {
  const config: PageActionsConfig;
  export default config;
}
