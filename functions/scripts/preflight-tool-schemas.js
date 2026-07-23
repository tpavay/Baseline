#!/usr/bin/env node
// Real-provider tool-schema preflight (docs/tool-schema-contract.md, layer 1).
//
// Submits EVERY served toolset variant - exactly as the runtime serves it, real system prompt
// included - to the actual Anthropic Messages API in the smallest possible request
// (max_tokens: 1, one-word user message), and fails if the provider rejects any. This is the
// ground truth the offline lint (toolSchemaContract.ts) approximates: the 2026-07 outage was a
// schema construct that only the provider's own request validator caught. Run by CI on every
// functions PR; run locally with:
//
//   ANTHROPIC_API_KEY=... npm run preflight:providers
//
// Cost: one ~tool-schema-sized input per variant with a 1-token completion - a schema-acceptance
// check, not a generation. Requires `npm run build` first (reads ../lib).
"use strict";

const { SERVED_TOOLSETS } = require("../lib/tools");
const { buildSystemBlocks } = require("../lib/prompt");
const { buildConversationProviderRequest, DEFAULT_CONVERSATION_MODEL } = require("../lib/provider");
const { isCreditExhaustion, warnProviderOutage } = require("./provider-outage");

const API_URL = "https://api.anthropic.com/v1/messages";
const MODEL = process.env.CONVERSATION_MODEL || DEFAULT_CONVERSATION_MODEL;
const MAX_ATTEMPTS = 4;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function preflightVariant(apiKey, toolsetName, tools) {
  // Built by the exact runtime request builder, prompt-caching breakpoints included (see
  // promptCaching.ts) - a provider rejecting `cache_control` placement must fail here, not in
  // production. Only max_tokens differs: 1 token, a schema-acceptance check.
  const request = buildConversationProviderRequest(MODEL, {
    system: buildSystemBlocks(toolsetName),
    tools,
    messages: [{ role: "user", content: "ping" }],
  });
  request.max_tokens = 1;
  const body = JSON.stringify(request);

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
      return { ok: true };
    }
    const text = await response.text();
    // Retry transient failures (rate limit, overload, server error); a schema rejection is a
    // deterministic 4xx and retrying it would only waste requests.
    if ((response.status === 429 || response.status >= 500) && attempt < MAX_ATTEMPTS) {
      const retryAfter = Number(response.headers.get("retry-after"));
      const delayMs = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : attempt * 2000;
      console.log(`  ${toolsetName}: transient ${response.status}, retrying in ${delayMs}ms (attempt ${attempt}/${MAX_ATTEMPTS})`);
      await sleep(delayMs);
      continue;
    }
    // An exhausted credit balance also arrives as a 400 invalid_request_error, but it is a
    // billing outage, not a schema verdict - classify it apart so it cannot be misreported as
    // "the provider rejected this schema" (see provider-outage.js).
    if (isCreditExhaustion(text)) {
      return { ok: false, billingOutage: true, status: response.status, detail: text };
    }
    return { ok: false, status: response.status, detail: text };
  }
  return { ok: false, status: 0, detail: "retries exhausted" };
}

async function main() {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    console.error(
      "ANTHROPIC_API_KEY is not set. In CI this comes from the repository Actions secret " +
      "ANTHROPIC_API_KEY; locally, export a key before running. The preflight fails rather than " +
      "skips: without it a provider-rejected schema could reach a green build."
    );
    process.exit(1);
  }

  const variants = Object.entries(SERVED_TOOLSETS);
  console.log(`Preflighting ${variants.length} served toolset variants against ${MODEL} (anthropic)…`);

  const failures = [];
  let sawBillingOutage = false;
  for (const [toolsetName, tools] of variants) {
    const result = await preflightVariant(apiKey, toolsetName, tools);
    if (result.ok) {
      console.log(`  ✓ ${toolsetName} (${tools.length} tools) accepted`);
    } else if (result.billingOutage) {
      console.error(`  ⚠ ${toolsetName} (${tools.length} tools) UNVERIFIED - provider credit balance exhausted`);
      sawBillingOutage = true;
    } else {
      console.error(`  ✗ ${toolsetName} (${tools.length} tools) REJECTED - HTTP ${result.status}\n    ${result.detail}`);
      failures.push(toolsetName);
    }
  }

  if (failures.length > 0) {
    console.error(
      `\nProvider rejected ${failures.length} toolset variant(s): ${failures.join(", ")}.\n` +
      "Every conversation request served that toolset would fail with the same error. " +
      "Fix the schema (see docs/tool-schema-contract.md) - do not merge."
    );
    process.exit(1);
  }
  if (sawBillingOutage) {
    warnProviderOutage("Tool-schema preflight");
    return;
  }
  console.log("All served toolset variants accepted by the provider.");
}

main().catch((error) => {
  console.error("Preflight crashed:", error);
  process.exit(1);
});
