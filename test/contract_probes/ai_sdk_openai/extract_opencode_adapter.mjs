import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const moduleDir = dirname(fileURLToPath(import.meta.url));
const generatedPath = join(moduleDir, "opencode_error_adapter.generated.mjs");
const provenancePath = join(moduleDir, "opencode_adapter_provenance.json");
const expectedCommit = "67caf894e0843ee370e72839e8265e483233479b";

const args = process.argv.slice(2);
const check = args.includes("--check");
const commitIndex = args.indexOf("--source-commit");
const sourceCommit = commitIndex >= 0 ? args[commitIndex + 1] : undefined;
const sourcePath = args.find((arg, index) => !arg.startsWith("--") && index !== commitIndex + 1);

assert.equal(sourceCommit, expectedCommit);
assert.ok(sourcePath);

const sourceBytes = await readFile(resolve(sourcePath));
const sourceText = sourceBytes.toString("utf8");
const sourceFile = ts.createSourceFile("ai-sdk.ts", sourceText, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
let errorClause;

function visit(node) {
  if (
    ts.isFunctionDeclaration(node) &&
    node.name?.text === "toLLMEvents" &&
    node.body
  ) {
    const switchStatement = node.body.statements.find(ts.isSwitchStatement);
    assert.ok(switchStatement);
    errorClause = switchStatement.caseBlock.clauses.find(
      (clause) => ts.isCaseClause(clause) && ts.isStringLiteral(clause.expression) && clause.expression.text === "error",
    );
    return;
  }

  ts.forEachChild(node, visit);
}

visit(sourceFile);
assert.ok(errorClause);
assert.equal(errorClause.statements.length, 1);

const returnStatement = errorClause.statements[0];
assert.ok(ts.isReturnStatement(returnStatement));
assert.ok(returnStatement.expression && ts.isCallExpression(returnStatement.expression));
assert.equal(returnStatement.expression.expression.getText(sourceFile), "Effect.fail");
assert.equal(returnStatement.expression.arguments.length, 1);
assert.equal(returnStatement.expression.arguments[0].getText(sourceFile), "event.error");

const spanStart = errorClause.getStart(sourceFile);
const spanEnd = errorClause.end;
const sourceSpan = sourceText.slice(spanStart, spanEnd);
const normalizedAst = ts
  .createPrinter({ newLine: ts.NewLineKind.LineFeed, removeComments: true })
  .printNode(ts.EmitHint.Unspecified, errorClause, sourceFile)
  .trim();

const generated = [
  'import { Effect } from "effect";',
  "",
  "export function applyOpenCodeErrorAdapter(event) {",
  "  switch (event.type) {",
  sourceSpan
    .split("\n")
    .map((line) => `    ${line}`)
    .join("\n"),
  "    default:",
  '      throw new Error("unsupported adapter event")',
  "  }",
  "}",
  "",
].join("\n");

const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const provenance = {
  opencode_version: "1.18.3",
  source_commit: sourceCommit,
  source_file: "packages/opencode/src/session/llm/ai-sdk.ts",
  source_file_sha256: sha256(sourceBytes),
  byte_span: { start: spanStart, end: spanEnd },
  byte_span_sha256: sha256(sourceSpan),
  normalized_ast_sha256: sha256(normalizedAst),
  generated_file_sha256: sha256(generated),
};

if (check) {
  assert.equal(await readFile(generatedPath, "utf8"), generated);
  assert.deepEqual(JSON.parse(await readFile(provenancePath, "utf8")), provenance);
} else {
  await writeFile(generatedPath, generated);
  await writeFile(provenancePath, `${JSON.stringify(provenance, null, 2)}\n`);
}
