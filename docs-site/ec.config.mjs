import { defineEcConfig } from "@astrojs/starlight/expressive-code";
import { releaseVersionCode } from "./plugins/release-version.mjs";
import promql from "./syntax/promql.tmLanguage.json" with { type: "json" };

// On touch screens (no hover) Expressive Code keeps the copy button visible over the top-right of the
// code, where it hides the end of the first line. There, terminal and titled frames carry the button in
// their title bar (a little taller), and plain frames start their code below it. Hover devices keep
// the default button that appears on hover. Expressive Code scopes these styles to `.expressive-code`.
const touchCopyButton = {
  name: "codex-pooler-touch-copy-button",
  baseStyles: `
    @media (hover: none) {
      .frame .copy button {
        width: 2rem;
        height: 2rem;
      }
      .frame.is-terminal,
      .frame.has-title:not(.is-terminal) {
        --ec-uiPadBlk: 0.375rem;
        --button-spacing: calc((2 * var(--ec-uiPadBlk) + var(--ec-uiFontSize) * var(--ec-uiLineHt) - 2rem) / 2);
      }
      .frame.is-terminal .header,
      .frame.has-title:not(.is-terminal) .header {
        padding-inline-end: 3rem;
      }
      .frame:not(.is-terminal, .has-title) pre > code {
        padding-block-start: calc(var(--button-spacing) + 2.25rem);
      }
    }
  `,
};

export default defineEcConfig({
  styleOverrides: { codeFontSize: "0.775rem" },
  shiki: { langs: [promql] },
  plugins: [releaseVersionCode, touchCopyButton],
});
