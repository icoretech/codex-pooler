import { defineEcConfig } from "@astrojs/starlight/expressive-code";
import promql from "./syntax/promql.tmLanguage.json" with { type: "json" };

export default defineEcConfig({
  styleOverrides: { codeFontSize: "0.775rem" },
  shiki: { langs: [promql] },
});
