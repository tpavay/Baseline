#!/usr/bin/env node
// Tool-schema token measurement (companion to the provider preflight; see toolSchemaTokens.ts).
//
// Bytes are not tokens: the wave9 toolset is 75,770 bytes of JSON but 22,213 input tokens of
// per-request overhead. This script measures the real token cost of every served toolset variant
// (and both workout-import request shapes) with Anthropic's FREE `count_tokens` endpoint, plus a
// per-tool marginal table for the richest toolset, and maintains the committed fixture
// `src/toolSchemaTokens.json` the runtime records as `tool_schema_tokens` on every generation.
//
//   ANTHROPIC_API_KEY=... npm run tokens:measure   # rewrite the fixture locally
//   ANTHROPIC_API_KEY=... npm run tokens:check     # CI: fail when the fixture is stale
//
// Contributors without a local key use the read-only workflow documented in this directory's
// README. The workflow separates keyless feature-branch input export from trusted measurement on
// the default branch, so feature-branch code never runs in a process that can read the secret.
//
// The check runs in the free per-PR CI job `functions-token-fixture` (count_tokens is not billed),
// so a PR that changes any served schema must regenerate the fixture. This is a COST guard only:
// count_tokens does NOT validate schemas, so provider acceptance is guarded offline by
// toolSchemaContract.ts and by the gated real-messages preflight. Token counts are deterministic
// per (model, input), so check mode is exact. Requires `npm run build` first (reads ../lib).
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const { isCreditExhaustion, warnProviderOutage } = require("./provider-outage");

const API_URL = "https://api.anthropic.com/v1/messages/count_tokens";
const FIXTURE_PATH = path.join(__dirname, "..", "src", "toolSchemaTokens.json");
const INPUT_FORMAT_VERSION = 1;
const MAX_ATTEMPTS = 5;
const MAX_INPUT_BYTES = 10 * 1024 * 1024;
const MAX_SYSTEM_BYTES = 512 * 1024;
const MAX_TOOL_COUNT = 250;
const MAX_SHAPE_COUNT = 20;
// The per-tool sweep for the richest toolset alone is ~80 requests. A small pool keeps the run
// under a minute without tripping rate limits.
const CONCURRENCY = 6;
const FIXTURE_NOTE =
  "Measured by scripts/measure-tool-schema-tokens.js via Anthropic count_tokens; do not " +
  "edit by hand. toolSchemaTokens = count(prompt+tools) - count(prompt) and includes the " +
  "provider's fixed tool-use system overhead once; conversationTools rows each include that " +
  "same overhead and are for relative attribution, not summation.";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function countTokens(apiKey, model, system, tools) {
  const body = JSON.stringify({
    model,
    system,
    ...(tools.length > 0 ? { tools } : {}),
    messages: [{ role: "user", content: "ping" }],
  });
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    const response = await fetch(API_URL, {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body,
    });
    if (response.ok) {
      const parsed = await response.json();
      if (!Number.isInteger(parsed.input_tokens)) {
        throw new Error(`count_tokens returned no input_tokens: ${JSON.stringify(parsed)}`);
      }
      return parsed.input_tokens;
    }
    const text = await response.text();
    if ((response.status === 429 || response.status >= 500) && attempt < MAX_ATTEMPTS) {
      const retryAfter = Number(response.headers.get("retry-after"));
      const delayMs = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : attempt * 2000;
      await sleep(delayMs);
      continue;
    }
    throw new Error(`count_tokens failed with HTTP ${response.status}: ${text}`);
  }
  throw new Error("count_tokens retries exhausted");
}

async function mapWithPool(items, worker) {
  const results = new Array(items.length);
  let next = 0;
  const lanes = Array.from({ length: Math.min(CONCURRENCY, items.length) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await worker(items[index]);
    }
  });
  await Promise.all(lanes);
  return results;
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validateShape(label, shape) {
  if (!isPlainObject(shape)) {
    throw new Error(`${label} must be an object`);
  }
  if (typeof shape.system !== "string" || shape.system.length === 0) {
    throw new Error(`${label}.system must be a non-empty string`);
  }
  if (Buffer.byteLength(shape.system, "utf8") > MAX_SYSTEM_BYTES) {
    throw new Error(`${label}.system exceeds ${MAX_SYSTEM_BYTES} bytes`);
  }
  if (!Array.isArray(shape.tools) || shape.tools.length > MAX_TOOL_COUNT) {
    throw new Error(`${label}.tools must be an array with at most ${MAX_TOOL_COUNT} entries`);
  }
  for (const [index, tool] of shape.tools.entries()) {
    if (!isPlainObject(tool)) {
      throw new Error(`${label}.tools[${index}] must be an object`);
    }
    if (
      typeof tool.name !== "string" ||
      tool.name.length === 0 ||
      tool.name.length > 128 ||
      !/^[A-Za-z0-9_-]+$/.test(tool.name)
    ) {
      throw new Error(`${label}.tools[${index}] contains an invalid tool name`);
    }
  }
}

function validateShapeMap(label, shapes) {
  if (!isPlainObject(shapes)) {
    throw new Error(`${label} must be an object`);
  }
  const entries = Object.entries(shapes);
  if (entries.length === 0 || entries.length > MAX_SHAPE_COUNT) {
    throw new Error(`${label} must contain between 1 and ${MAX_SHAPE_COUNT} request shapes`);
  }
  for (const [name, shape] of entries) {
    if (!/^[a-z0-9_-]+$/.test(name)) {
      throw new Error(`${label} contains an unsafe request-shape name: ${JSON.stringify(name)}`);
    }
    validateShape(`${label}.${name}`, shape);
  }
}

function validateMeasurementInputs(inputs) {
  if (!isPlainObject(inputs)) {
    throw new Error("measurement inputs must be an object");
  }
  const serializedBytes = Buffer.byteLength(JSON.stringify(inputs), "utf8");
  if (serializedBytes > MAX_INPUT_BYTES) {
    throw new Error(`measurement inputs exceed ${MAX_INPUT_BYTES} bytes`);
  }
  if (inputs.version !== INPUT_FORMAT_VERSION) {
    throw new Error(
      `unsupported measurement input version ${JSON.stringify(inputs.version)}; ` +
      `expected ${INPUT_FORMAT_VERSION}`,
    );
  }
  if (
    typeof inputs.model !== "string" ||
    inputs.model.length === 0 ||
    inputs.model.length > 128 ||
    !/^[A-Za-z0-9._:-]+$/.test(inputs.model)
  ) {
    throw new Error("measurement inputs contain an invalid model");
  }
  validateShapeMap("conversation", inputs.conversation);
  validateShapeMap("import", inputs.import);
  if (
    typeof inputs.attributionToolset !== "string" ||
    !Object.hasOwn(inputs.conversation, inputs.attributionToolset)
  ) {
    throw new Error("attributionToolset must name a conversation request shape");
  }
  return inputs;
}

function buildMeasurementInputs() {
  // Load compiled feature-branch code only in the keyless export and local modes. The secret-bearing
  // workflow mode reads a JSON artifact and never imports or executes feature-branch code.
  const { SERVED_TOOLSETS } = require("../lib/tools");
  const { buildSystem } = require("../lib/prompt");
  const { DEFAULT_CONVERSATION_MODEL } = require("../lib/provider");
  const { WORKOUT_IMPORT_SYSTEM, WORKOUT_IMPORT_TOOL } = require("../lib/workoutImport");
  const {
    WORKOUT_IMPORT_SKETCH_SYSTEM,
    WORKOUT_IMPORT_SKETCH_TOOL,
  } = require("../lib/workoutImportStream");

  const conversation = Object.fromEntries(
    Object.entries(SERVED_TOOLSETS).map(([name, tools]) => [
      name,
      { system: buildSystem(name), tools },
    ]),
  );
  return validateMeasurementInputs({
    version: INPUT_FORMAT_VERSION,
    model: DEFAULT_CONVERSATION_MODEL,
    conversation,
    attributionToolset: Object.keys(conversation)[0],
    import: {
      durable: { system: WORKOUT_IMPORT_SYSTEM, tools: [WORKOUT_IMPORT_TOOL] },
      sketch: { system: WORKOUT_IMPORT_SKETCH_SYSTEM, tools: [WORKOUT_IMPORT_SKETCH_TOOL] },
    },
  });
}

async function measureRequestShape(counter, system, tools) {
  const promptTokens = await counter(system, []);
  const promptWithToolsTokens = await counter(system, tools);
  return {
    toolCount: tools.length,
    promptTokens,
    promptWithToolsTokens,
    toolSchemaTokens: promptWithToolsTokens - promptTokens,
  };
}

async function measureInputs(rawInputs, counter) {
  const inputs = validateMeasurementInputs(rawInputs);
  const conversation = {};
  for (const [toolsetName, shape] of Object.entries(inputs.conversation)) {
    conversation[toolsetName] = await measureRequestShape(counter, shape.system, shape.tools);
    console.log(
      `  ${toolsetName}: ${conversation[toolsetName].toolSchemaTokens} tool tokens ` +
      `on a ${conversation[toolsetName].promptTokens}-token prompt (${shape.tools.length} tools)`,
    );
  }

  // Every marginal includes Anthropic's fixed tool-use system overhead once, so rows compare
  // against each other but do not sum to the toolset total.
  const richestName = inputs.attributionToolset;
  const richest = inputs.conversation[richestName];
  const promptTokens = conversation[richestName].promptTokens;
  const marginals = await mapWithPool(richest.tools, async (tool) => {
    const withOne = await counter(richest.system, [tool]);
    return [tool.name, withOne - promptTokens];
  });
  const conversationTools = Object.fromEntries(
    marginals.sort(([a], [b]) => a.localeCompare(b)),
  );
  console.log(`  per-tool marginals measured for ${richestName} (${marginals.length} tools)`);

  const importShapes = {};
  for (const [name, shape] of Object.entries(inputs.import)) {
    importShapes[name] = await measureRequestShape(counter, shape.system, shape.tools);
  }
  console.log(
    `  import: ${Object.entries(importShapes)
      .map(([name, shape]) => `${name} ${shape.toolSchemaTokens}`)
      .join(", ")} tool tokens`,
  );

  return {
    note: FIXTURE_NOTE,
    model: inputs.model,
    conversation,
    conversationTools,
    import: importShapes,
  };
}

function diffFixtures(committed, measured, prefix = "", lines = []) {
  const keys = new Set([...Object.keys(committed ?? {}), ...Object.keys(measured ?? {})]);
  for (const key of keys) {
    const a = committed?.[key];
    const b = measured?.[key];
    if (isPlainObject(a) && isPlainObject(b)) {
      diffFixtures(a, b, `${prefix}${key}.`, lines);
    } else if (a !== b) {
      lines.push(`  ${prefix}${key}: committed ${JSON.stringify(a)} -> measured ${JSON.stringify(b)}`);
    }
  }
  return lines;
}

function optionValue(flag) {
  const index = process.argv.indexOf(flag);
  if (index === -1) {
    return undefined;
  }
  const value = process.argv[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function writeJson(outputPath, value) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

function requireApiKey() {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    throw new Error(
      "ANTHROPIC_API_KEY is not set. CI checks use the repository Actions secret. " +
      "Contributors without a local key can regenerate through " +
      ".github/workflows/regenerate-tool-schema-token-fixture.yml; see functions/scripts/README.md.",
    );
  }
  return apiKey;
}

async function main() {
  const exportInputsPath = optionValue("--export-inputs");
  const measureInputsPath = optionValue("--measure-inputs");
  const outputPath = optionValue("--output");
  const writeMode = process.argv.includes("--write");
  const selectedModes = [Boolean(exportInputsPath), Boolean(measureInputsPath), writeMode].filter(Boolean);
  if (selectedModes.length > 1) {
    throw new Error("choose only one of --export-inputs, --measure-inputs, or --write");
  }

  if (exportInputsPath) {
    writeJson(path.resolve(exportInputsPath), buildMeasurementInputs());
    console.log(`Exported keyless measurement inputs to ${exportInputsPath}.`);
    return;
  }

  let inputs;
  let mode;
  let destination;
  if (measureInputsPath) {
    if (!outputPath) {
      throw new Error("--measure-inputs requires --output");
    }
    inputs = validateMeasurementInputs(
      JSON.parse(fs.readFileSync(path.resolve(measureInputsPath), "utf8")),
    );
    mode = "write";
    destination = path.resolve(outputPath);
  } else {
    inputs = buildMeasurementInputs();
    mode = writeMode ? "write" : "check";
    destination = FIXTURE_PATH;
  }

  const apiKey = requireApiKey();
  console.log(`Counting tool-schema tokens against ${inputs.model} (anthropic count_tokens, free)...`);
  let measured;
  try {
    measured = await measureInputs(
      inputs,
      (system, tools) => countTokens(apiKey, inputs.model, system, tools),
    );
  } catch (error) {
    // A billing outage cannot verify or produce a fixture. Check mode reports a loud skip rather
    // than a false stale-fixture verdict. Write modes still fail and never write partial output.
    if (mode === "check" && isCreditExhaustion(error.message)) {
      warnProviderOutage("Token-fixture check");
      return;
    }
    throw error;
  }

  if (mode === "write") {
    writeJson(destination, measured);
    console.log(`Wrote ${path.relative(process.cwd(), destination)}. Commit the diff.`);
    return;
  }

  const committed = JSON.parse(fs.readFileSync(FIXTURE_PATH, "utf8"));
  const differences = diffFixtures(committed, measured);
  if (differences.length > 0) {
    console.error(
      `\nsrc/toolSchemaTokens.json is stale (${differences.length} difference(s)):\n` +
      `${differences.join("\n")}\n\n` +
      "A schema or prompt change altered per-request token costs. Regenerate with the read-only\n" +
      "workflow in .github/workflows/regenerate-tool-schema-token-fixture.yml (instructions in\n" +
      "functions/scripts/README.md), or run npm run tokens:measure with a local key. Commit the\n" +
      "fixture diff so the token delta is visible in review.",
    );
    process.exitCode = 1;
    return;
  }
  console.log("Fixture matches live token counts.");
}

if (require.main === module) {
  main().catch((error) => {
    console.error("Token measurement crashed:", error.message);
    process.exit(1);
  });
}

module.exports = {
  INPUT_FORMAT_VERSION,
  buildMeasurementInputs,
  diffFixtures,
  measureInputs,
  validateMeasurementInputs,
};
