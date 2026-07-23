#!/usr/bin/env node
// Tool-schema token measurement (companion to the provider preflight; see toolSchemaTokens.ts).
//
// Bytes are not tokens: the wave9 toolset is 75,770 bytes of JSON but 22,213 input tokens of
// per-request overhead. This script measures the real token cost of every served toolset variant
// (and both workout-import request shapes) with Anthropic's FREE `count_tokens` endpoint, plus a
// per-tool marginal table for the richest toolset, and maintains the committed fixture
// `src/toolSchemaTokens.json` the runtime records as `tool_schema_tokens` on every generation.
//
//   ANTHROPIC_API_KEY=... npm run tokens:measure   # rewrite the fixture (then commit the diff)
//   ANTHROPIC_API_KEY=... npm run tokens:check     # CI: fail when the fixture is stale
//
// The check runs in the CI provider-preflight job, so a PR that changes any served schema must
// regenerate the fixture - which makes "this PR added N tokens to every request" a visible diff
// at review time. Token counts are deterministic per (model, input), so check mode is exact.
// Requires `npm run build` first (reads ../lib). Cost: ~90 free count_tokens requests.
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const { SERVED_TOOLSETS } = require("../lib/tools");
const { buildSystem } = require("../lib/prompt");
const { DEFAULT_CONVERSATION_MODEL } = require("../lib/provider");
const { WORKOUT_IMPORT_SYSTEM, WORKOUT_IMPORT_TOOL } = require("../lib/workoutImport");
const {
  WORKOUT_IMPORT_SKETCH_SYSTEM,
  WORKOUT_IMPORT_SKETCH_TOOL,
} = require("../lib/workoutImportStream");

const API_URL = "https://api.anthropic.com/v1/messages/count_tokens";
const MODEL = DEFAULT_CONVERSATION_MODEL;
const FIXTURE_PATH = path.join(__dirname, "..", "src", "toolSchemaTokens.json");
const MAX_ATTEMPTS = 5;
// The per-tool sweep for the richest toolset alone is ~80 requests; a small pool keeps the run
// under a minute without tripping rate limits.
const CONCURRENCY = 6;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function countTokens(apiKey, system, tools) {
  const body = JSON.stringify({
    model: MODEL,
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

async function measureRequestShape(apiKey, system, tools) {
  const promptTokens = await countTokens(apiKey, system, []);
  const promptWithToolsTokens = await countTokens(apiKey, system, tools);
  return {
    toolCount: tools.length,
    promptTokens,
    promptWithToolsTokens,
    toolSchemaTokens: promptWithToolsTokens - promptTokens,
  };
}

async function measure(apiKey) {
  const conversation = {};
  for (const [toolsetName, tools] of Object.entries(SERVED_TOOLSETS)) {
    conversation[toolsetName] = await measureRequestShape(apiKey, buildSystem(toolsetName), tools);
    console.log(
      `  ${toolsetName}: ${conversation[toolsetName].toolSchemaTokens} tool tokens ` +
      `on a ${conversation[toolsetName].promptTokens}-token prompt (${tools.length} tools)`
    );
  }

  // Per-tool marginal cost for the richest toolset, for attribution. Every row includes
  // Anthropic's fixed tool-use system overhead once (~500 tokens), so rows compare against each
  // other but do not sum to the toolset total.
  const richest = Object.entries(SERVED_TOOLSETS)[0];
  const promptTokens = conversation[richest[0]].promptTokens;
  const marginals = await mapWithPool(richest[1], async (tool) => {
    const withOne = await countTokens(apiKey, buildSystem(richest[0]), [tool]);
    return [tool.name, withOne - promptTokens];
  });
  const conversationTools = Object.fromEntries(
    marginals.sort(([a], [b]) => a.localeCompare(b)),
  );
  console.log(`  per-tool marginals measured for ${richest[0]} (${marginals.length} tools)`);

  const importShapes = {
    durable: await measureRequestShape(apiKey, WORKOUT_IMPORT_SYSTEM, [WORKOUT_IMPORT_TOOL]),
    sketch: await measureRequestShape(
      apiKey,
      WORKOUT_IMPORT_SKETCH_SYSTEM,
      [WORKOUT_IMPORT_SKETCH_TOOL],
    ),
  };
  console.log(
    `  import: durable ${importShapes.durable.toolSchemaTokens}, ` +
    `sketch ${importShapes.sketch.toolSchemaTokens} tool tokens`
  );

  return {
    note:
      "Measured by scripts/measure-tool-schema-tokens.js via Anthropic count_tokens; do not " +
      "edit by hand. toolSchemaTokens = count(prompt+tools) - count(prompt) and includes the " +
      "provider's fixed tool-use system overhead once; conversationTools rows each include that " +
      "same overhead and are for relative attribution, not summation.",
    model: MODEL,
    conversation,
    conversationTools,
    import: importShapes,
  };
}

function diffFixtures(committed, measured, prefix, lines) {
  const keys = new Set([...Object.keys(committed ?? {}), ...Object.keys(measured ?? {})]);
  for (const key of keys) {
    const a = committed?.[key];
    const b = measured?.[key];
    if (typeof a === "object" && a !== null && typeof b === "object" && b !== null) {
      diffFixtures(a, b, `${prefix}${key}.`, lines);
    } else if (a !== b) {
      lines.push(`  ${prefix}${key}: committed ${JSON.stringify(a)} -> measured ${JSON.stringify(b)}`);
    }
  }
  return lines;
}

async function main() {
  const mode = process.argv.includes("--write") ? "write" : "check";
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    console.error(
      "ANTHROPIC_API_KEY is not set. In CI this comes from the repository Actions secret " +
      "ANTHROPIC_API_KEY; locally, export a key before running. The check fails rather than " +
      "skips: a silently stale fixture would misattribute schema tokens on every generation."
    );
    process.exit(1);
  }

  console.log(`Counting tool-schema tokens against ${MODEL} (anthropic count_tokens, free)…`);
  const measured = await measure(apiKey);
  const serialized = `${JSON.stringify(measured, null, 2)}\n`;

  if (mode === "write") {
    fs.writeFileSync(FIXTURE_PATH, serialized);
    console.log(`Wrote ${path.relative(process.cwd(), FIXTURE_PATH)}. Commit the diff.`);
    return;
  }

  const committed = JSON.parse(fs.readFileSync(FIXTURE_PATH, "utf8"));
  const differences = diffFixtures(committed, measured, "", []);
  if (differences.length > 0) {
    console.error(
      `\nsrc/toolSchemaTokens.json is stale (${differences.length} difference(s)):\n` +
      `${differences.join("\n")}\n\n` +
      "A schema or prompt change altered per-request token costs. Regenerate with\n" +
      "  ANTHROPIC_API_KEY=... npm run tokens:measure\n" +
      "and commit the fixture diff so the token delta is visible in review."
    );
    process.exit(1);
  }
  console.log("Fixture matches live token counts.");
}

main().catch((error) => {
  console.error("Token measurement crashed:", error);
  process.exit(1);
});
