import { readdir, readFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const docsSiteRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const canonicalHost = "https://docs.codex-pooler.com";
const inventoryScopeMarker =
  "Inventory scope: curated primary and discovery pages listed below; this index intentionally excludes other rendered pages.";
const llmsPath = resolve(process.env.LLMS_PATH ?? join(docsSiteRoot, "public/llms.txt"));
const sitemapPath = resolve(
  process.env.SITEMAP_PATH ?? join(docsSiteRoot, "public/sitemap-static.xml")
);
const docsRoot = join(docsSiteRoot, "src/content/docs");

const expectedInventory = {
  primary: [
    "/getting-started/quick-start/",
    "/getting-started/configuration/",
    "/clients/codex-cli/",
    "/clients/openai-compatible/",
    "/clients/aider/",
    "/clients/continue/",
    "/clients/cline/",
    "/clients/goose/",
    "/clients/kilo/",
    "/clients/opencode/",
    "/clients/openclaw/",
    "/clients/openhands/",
    "/clients/omp/",
    "/clients/pi/",
    "/clients/trae/",
    "/clients/hermes/",
    "/clients/windmill/",
    "/reference/runtime-routes/",
    "/reference/routing-strategies/",
    "/reference/responses-lite-vs-full/",
    "/operators/admin-ui/",
    "/operators/alerts/",
    "/operators/monitoring/",
    "/deployment/docker-compose/",
    "/deployment/helm/",
  ],
  discovery: [
    "/discovery/ai-coding-agent-gateway/",
    "/discovery/self-hosted-codex-gateway/",
    "/discovery/codex-account-pooling/",
    "/discovery/openai-compatible-codex-gateway/",
    "/discovery/codex-pooler-vs-direct-credentials/",
  ],
};

const expectedHeaderUrls = ["/", "/llms.txt", "/answers.md", "/pricing.md"];

const fail = (message) => {
  throw new Error(`llms inventory: ${message}`);
};

const canonicalUrl = (path) => `${canonicalHost}${path}`;

const read = (path) => readFile(path, "utf8");

const parseSection = (text, heading) => {
  const headingIndex = text.indexOf(`${heading}:`);
  if (headingIndex === -1) fail(`missing section ${heading}`);

  const sectionStart = headingIndex + heading.length + 1;
  const nextHeading = text.indexOf("\n\n", sectionStart);
  const section = text.slice(sectionStart, nextHeading === -1 ? text.length : nextHeading);

  return [...section.matchAll(/^[-*]\s+(https?:\/\/[^\s]+)$/gm)].map((match) => match[1]);
};

const parseHeaderUrls = (text) =>
  [...text.matchAll(/^(?:Canonical docs base|Canonical llms index|Short answer reference|Pricing and availability):\s+(\S+)$/gm)].map(
    (match) => match[1]
  );

const routeFromSource = (relativePath) => {
  const withoutExtension = relativePath.replace(/\.(?:md|mdx)$/u, "");
  if (withoutExtension === "index") return "/";
  return `/${withoutExtension}/`;
};

const sourceRoutes = async (directory = docsRoot) => {
  const entries = await readdir(directory, { withFileTypes: true });
  const routes = [];

  for (const entry of entries) {
    const absolutePath = join(directory, entry.name);
    if (entry.isDirectory()) {
      routes.push(...(await sourceRoutes(absolutePath)));
    } else if (/\.(?:md|mdx)$/u.test(entry.name) && !entry.name.startsWith("_")) {
      routes.push(routeFromSource(relative(docsRoot, absolutePath)));
    }
  }

  return routes;
};

const assertExactList = (label, actual, expected) => {
  const expectedUrls = expected.map(canonicalUrl);
  const missing = expectedUrls.filter((url) => !actual.includes(url));
  const extra = actual.filter((url) => !expectedUrls.includes(url));

  if (missing.length > 0) fail(`${label} missing entry/entries: ${missing.join(", ")}`);
  if (extra.length > 0) fail(`${label} extra entry/entries: ${extra.join(", ")}`);
  if (actual.length !== expectedUrls.length) {
    fail(`${label} has ${actual.length} entries; expected ${expectedUrls.length}`);
  }

  for (const [index, expectedUrl] of expectedUrls.entries()) {
    if (actual[index] !== expectedUrl) {
      fail(`${label} entry ${index + 1} is ${actual[index] ?? "missing"}; expected ${expectedUrl}`);
    }
  }
};

const assertCanonicalInventoryUrls = (urls) => {
  const malformed = urls.filter((url) => {
    try {
      const parsed = new URL(url);
      return parsed.origin !== canonicalHost || parsed.search || parsed.hash;
    } catch {
      return true;
    }
  });

  if (malformed.length > 0) {
    fail(`malformed canonical inventory URL(s): ${malformed.join(", ")}`);
  }

  const duplicates = urls.filter((url, index) => urls.indexOf(url) !== index);
  if (duplicates.length > 0) fail(`duplicate inventory URL(s): ${[...new Set(duplicates)].join(", ")}`);
};

const sitemapLastmodFor = (text, path) => {
  const match = text.match(
    new RegExp(`<loc>${canonicalUrl(path).replaceAll("/", "\\/")}<\\/loc>\\s*<lastmod>([^<]+)<\\/lastmod>`)
  );
  return match?.[1] ?? null;
};

const assertReviewDateRelationship = (llmsText, sitemapText) => {
  const reviewed = llmsText.match(/^Last reviewed:\s*(\d{4}-\d{2}-\d{2})$/m)?.[1];
  if (!reviewed) fail("Last reviewed must be a YYYY-MM-DD date");

  const sitemapDate = sitemapLastmodFor(sitemapText, "/llms.txt");
  if (!sitemapDate) fail("sitemap is missing the canonical /llms.txt entry or lastmod");
  if (sitemapDate !== reviewed) {
    fail(`sitemap /llms.txt lastmod ${sitemapDate} does not match Last reviewed ${reviewed}`);
  }
};

const [llmsText, sitemapText, routes] = await Promise.all([
  read(llmsPath),
  read(sitemapPath),
  sourceRoutes(),
]);

if (!llmsText.includes(inventoryScopeMarker)) {
  fail("missing explicit curated inventory scope marker");
}

const headerUrls = parseHeaderUrls(llmsText);
const primaryUrls = parseSection(llmsText, "Primary public docs");
const discoveryUrls = parseSection(llmsText, "AI search discovery pages");
const inventoryUrls = [...headerUrls, ...primaryUrls, ...discoveryUrls];
assertCanonicalInventoryUrls(inventoryUrls);
assertExactList("header inventory", headerUrls, expectedHeaderUrls);
assertExactList("primary inventory", primaryUrls, expectedInventory.primary);
assertExactList("discovery inventory", discoveryUrls, expectedInventory.discovery);

const expectedRoutes = [...expectedInventory.primary, ...expectedInventory.discovery];
const missingSourceRoutes = expectedRoutes.filter((route) => !routes.includes(route));
if (missingSourceRoutes.length > 0) {
  fail(`stale inventory route(s) with no source page: ${missingSourceRoutes.join(", ")}`);
}

const unexpectedInventoryRoutes = expectedRoutes.filter(
  (route) => !inventoryUrls.includes(canonicalUrl(route))
);
if (unexpectedInventoryRoutes.length > 0) {
  fail(`missing declared inventory route(s): ${unexpectedInventoryRoutes.join(", ")}`);
}

assertReviewDateRelationship(llmsText, sitemapText);

process.stdout.write(
  `llms inventory: PASS (${inventoryUrls.length} curated URLs; ${expectedRoutes.length} source-backed pages; /llms.txt review date matches sitemap)\n`
);
