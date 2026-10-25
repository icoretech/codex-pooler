import manifest from "../../.release-please-manifest.json" with { type: "json" };

const releaseToken = "__CODEX_POOLER_RELEASE_VERSION__";

export function renderReleaseVersion(text, version = manifest["."]) {
  if (typeof version !== "string" || version.trim() === "") throw new TypeError("release manifest must provide a nonempty version");
  return text.replaceAll(releaseToken, version);
}

export const releaseVersionCode = {
  name: "codex-pooler-release-version",
  hooks: {
    preprocessCode: ({ codeBlock }) => {
      for (const line of codeBlock.getLines()) {
        const rendered = renderReleaseVersion(line.text);
        if (rendered !== line.text) line.editText(0, line.text.length, rendered);
      }
    },
  },
};
