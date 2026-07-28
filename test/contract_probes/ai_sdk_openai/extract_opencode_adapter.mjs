import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

// allow: SIZE_OK - the two-source extractor stays one provenance-audited executable.
const moduleDir = dirname(fileURLToPath(import.meta.url));
const adapterGeneratedPath = join(moduleDir, "opencode_error_adapter.generated.mjs");
const classifierGeneratedPath = join(moduleDir, "opencode_stream_error_classifier.generated.mjs");
const provenancePath = join(moduleDir, "opencode_adapter_provenance.json");
const expectedCommit = "67caf894e0843ee370e72839e8265e483233479b";
const opencodeVersion = "1.18.3";
const adapterSourceFile = "packages/opencode/src/session/llm/ai-sdk.ts";
const classifierSourceFile = "packages/opencode/src/provider/error.ts";
const diagnosticHost = {
  getCanonicalFileName: (fileName) => fileName,
  getCurrentDirectory: () => "",
  getNewLine: () => "\n",
};

const args = process.argv.slice(2);
const check = args.includes("--check");
assert.ok(args.filter((arg) => arg === "--check").length <= 1);

const commandArgs = args.filter((arg) => arg !== "--check");
assert.equal(commandArgs.length, 4);
assert.equal(commandArgs[0], "--source-commit");

const [, sourceCommit, adapterSourcePath, classifierSourcePath] = commandArgs;
assert.equal(sourceCommit, expectedCommit);
assert.ok(adapterSourcePath && !adapterSourcePath.startsWith("--"));
assert.ok(classifierSourcePath && !classifierSourcePath.startsWith("--"));
assert.equal(adapterSourcePath.endsWith(adapterSourceFile), true);
assert.equal(classifierSourcePath.endsWith(classifierSourceFile), true);

const adapterSourceBytes = await readFile(resolve(adapterSourcePath));
const classifierSourceBytes = await readFile(resolve(classifierSourcePath));
const adapterExtraction = extractAdapter(adapterSourceBytes.toString("utf8"));
const classifierExtraction = extractClassifier(classifierSourceBytes.toString("utf8"));

const provenance = {
  opencode_version: opencodeVersion,
  sources: [
    sourceRecord({
      sourceCommit,
      sourceFile: adapterSourceFile,
      sourceBytes: adapterSourceBytes,
      extraction: adapterExtraction,
      generatedFile: "opencode_error_adapter.generated.mjs",
      exportedSymbol: "applyOpenCodeErrorAdapter",
    }),
    sourceRecord({
      sourceCommit,
      sourceFile: classifierSourceFile,
      sourceBytes: classifierSourceBytes,
      extraction: classifierExtraction,
      generatedFile: "opencode_stream_error_classifier.generated.mjs",
      exportedSymbol: "parseStreamError",
    }),
  ],
};

if (check) {
  assert.equal(await readFile(adapterGeneratedPath, "utf8"), adapterExtraction.generated);
  assert.equal(await readFile(classifierGeneratedPath, "utf8"), classifierExtraction.generated);
  assert.deepEqual(JSON.parse(await readFile(provenancePath, "utf8")), provenance);
} else {
  await writeFile(adapterGeneratedPath, adapterExtraction.generated);
  await writeFile(classifierGeneratedPath, classifierExtraction.generated);
  await writeFile(provenancePath, `${JSON.stringify(provenance, null, 2)}\n`);
}

function extractAdapter(sourceText) {
  const sourceFile = ts.createSourceFile(
    "ai-sdk.ts",
    sourceText,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  let errorClause;

  function visit(node) {
    if (ts.isFunctionDeclaration(node) && node.name?.text === "toLLMEvents" && node.body) {
      const switchStatement = node.body.statements.find(ts.isSwitchStatement);
      assert.ok(switchStatement);
      errorClause = switchStatement.caseBlock.clauses.find(
        (clause) =>
          ts.isCaseClause(clause) &&
          ts.isStringLiteral(clause.expression) &&
          clause.expression.text === "error",
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
  const normalizedAst = printNormalized(errorClause, sourceFile);
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

  return {
    byteSpan: { start: spanStart, end: spanEnd },
    sourceSpan,
    normalizedAst,
    generated,
  };
}

function extractClassifier(sourceText) {
  const sourceFile = ts.createSourceFile(
    "error.ts",
    sourceText,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  const declarations = sourceFile.statements.filter(
    (statement) =>
      ts.isFunctionDeclaration(statement) &&
      (statement.name?.text === "json" || statement.name?.text === "parseStreamError"),
  );

  assert.equal(declarations.length, 2);
  assert.deepEqual(
    declarations.map((declaration) => declaration.name?.text),
    ["json", "parseStreamError"],
  );

  const [jsonDeclaration, parseStreamErrorDeclaration] = declarations;
  assert.ok(jsonDeclaration.body);
  assert.ok(parseStreamErrorDeclaration.body);
  assertParseStreamErrorGates(parseStreamErrorDeclaration, sourceFile);

  const byteSpan = declarations.map((declaration) => ({
    start: declaration.getStart(sourceFile),
    end: declaration.end,
  }));
  const sourceSpan = byteSpan
    .map(({ start, end }) => sourceText.slice(start, end))
    .join("\n\n");
  const extractedSourceFile = ts.createSourceFile(
    "opencode-stream-error-classifier.ts",
    sourceSpan,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );

  assert.equal(extractedSourceFile.statements.length, 2);
  assert.ok(extractedSourceFile.statements.every(ts.isFunctionDeclaration));
  assert.deepEqual(
    extractedSourceFile.statements.map((declaration) => declaration.name?.text),
    ["json", "parseStreamError"],
  );
  assert.equal(extractedSourceFile.statements.some(ts.isImportDeclaration), false);
  assert.deepEqual(collectCallExpressions(extractedSourceFile), [
    "JSON.parse",
    "JSON.stringify",
    "json",
  ]);

  const normalizedAst = declarations
    .map((declaration) => printNormalized(declaration, sourceFile))
    .join("\n\n");
  const transpiled = ts.transpileModule(sourceSpan, {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ESNext,
      removeComments: true,
    },
    reportDiagnostics: true,
  });
  const diagnostics = transpiled.diagnostics ?? [];
  assert.equal(diagnostics.length, 0, ts.formatDiagnostics(diagnostics, diagnosticHost));
  assertGeneratedClassifier(transpiled.outputText);

  return {
    byteSpan,
    sourceSpan,
    normalizedAst,
    generated: transpiled.outputText,
  };
}

function assertParseStreamErrorGates(declaration, sourceFile) {
  let hasTypeGate = false;
  let errorCodeSwitch;

  function visit(node) {
    if (
      ts.isIfStatement(node) &&
      ts.isBinaryExpression(node.expression) &&
      node.expression.operatorToken.kind === ts.SyntaxKind.ExclamationEqualsEqualsToken &&
      node.expression.left.getText(sourceFile) === "body.type" &&
      ts.isStringLiteral(node.expression.right) &&
      node.expression.right.text === "error" &&
      ts.isReturnStatement(node.thenStatement)
    ) {
      hasTypeGate = true;
    }

    if (ts.isSwitchStatement(node) && node.expression.getText(sourceFile) === "body?.error?.code") {
      errorCodeSwitch = node;
    }

    ts.forEachChild(node, visit);
  }

  visit(declaration);
  assert.equal(hasTypeGate, true);
  assert.ok(errorCodeSwitch);

  const serverErrorClause = errorCodeSwitch.caseBlock.clauses.find(
    (clause) =>
      ts.isCaseClause(clause) &&
      ts.isStringLiteral(clause.expression) &&
      clause.expression.text === "server_error",
  );
  assert.ok(serverErrorClause);

  const returnStatement = serverErrorClause.statements.find(ts.isReturnStatement);
  assert.ok(returnStatement?.expression && ts.isObjectLiteralExpression(returnStatement.expression));

  const retryableProperty = returnStatement.expression.properties.find(
    (property) =>
      ts.isPropertyAssignment(property) &&
      property.name.getText(sourceFile) === "isRetryable",
  );
  assert.ok(
    retryableProperty &&
      ts.isPropertyAssignment(retryableProperty) &&
      retryableProperty.initializer.kind === ts.SyntaxKind.TrueKeyword,
  );
}

function assertGeneratedClassifier(generated) {
  const sourceFile = ts.createSourceFile(
    "opencode_stream_error_classifier.generated.mjs",
    generated,
    ts.ScriptTarget.ES2022,
    true,
    ts.ScriptKind.JS,
  );
  assert.equal(sourceFile.parseDiagnostics.length, 0);
  assert.equal(sourceFile.statements.length, 2);
  assert.ok(sourceFile.statements.every(ts.isFunctionDeclaration));

  const [jsonDeclaration, parseStreamErrorDeclaration] = sourceFile.statements;
  assert.equal(jsonDeclaration.name?.text, "json");
  assert.equal(hasExportModifier(jsonDeclaration), false);
  assert.equal(parseStreamErrorDeclaration.name?.text, "parseStreamError");
  assert.equal(hasExportModifier(parseStreamErrorDeclaration), true);
}

function collectCallExpressions(sourceFile) {
  const calls = new Set();

  function visit(node) {
    if (ts.isCallExpression(node)) calls.add(node.expression.getText(sourceFile));
    ts.forEachChild(node, visit);
  }

  visit(sourceFile);
  return [...calls].sort();
}

function hasExportModifier(node) {
  return node.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword) ?? false;
}

function printNormalized(node, sourceFile) {
  return ts
    .createPrinter({ newLine: ts.NewLineKind.LineFeed, removeComments: true })
    .printNode(ts.EmitHint.Unspecified, node, sourceFile)
    .trim();
}

function sourceRecord({
  sourceCommit,
  sourceFile,
  sourceBytes,
  extraction,
  generatedFile,
  exportedSymbol,
}) {
  return {
    source_file: sourceFile,
    source_commit: sourceCommit,
    source_file_sha256: sha256(sourceBytes),
    byte_span: extraction.byteSpan,
    byte_span_sha256: sha256(extraction.sourceSpan),
    normalized_ast_sha256: sha256(extraction.normalizedAst),
    generated_file: generatedFile,
    generated_file_sha256: sha256(extraction.generated),
    exported_symbol: exportedSymbol,
  };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
