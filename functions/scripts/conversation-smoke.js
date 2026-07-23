#!/usr/bin/env node
// End-to-end conversation smoke test, one per provider (docs/tool-schema-contract.md, layer 4).
//
// Drives ONE real conversation round-trip through the same provider class the runtime uses
// (AnthropicProvider.complete), with the full richest served toolset and the real system prompt,
// and asserts the provider returns usable content blocks. Where the preflight proves the provider
// ACCEPTS each toolset, this proves a live conversation actually completes through the provider
// boundary - a broken served toolset fails a real exercise, not just a static check.
//
//   ANTHROPIC_API_KEY=... npm run smoke:conversation
//
// Requires `npm run build` first (reads ../lib). Cost: one request with a 1024-token cap.
"use strict";

const { AnthropicProvider } = require("../lib/provider");
const { SERVED_TOOLSETS } = require("../lib/tools");
const { buildSystemBlocks } = require("../lib/prompt");

// One entry per supported provider. Adding a provider: implement ConversationProvider, add its
// constraint profile to toolSchemaContract.ts, and register a factory here.
const PROVIDERS = [
  {
    id: "anthropic",
    make: (env) => new AnthropicProvider(env.ANTHROPIC_API_KEY, env.CONVERSATION_MODEL),
    keyEnvVar: "ANTHROPIC_API_KEY",
  },
];

async function smokeProvider({ id, make, keyEnvVar }) {
  if (!process.env[keyEnvVar]) {
    throw new Error(
      `${keyEnvVar} is not set. In CI this comes from the repository Actions secret; the smoke ` +
      "test fails rather than skips so a broken provider path cannot reach a green build."
    );
  }
  const provider = make(process.env);
  const blocks = await provider.complete({
    system: buildSystemBlocks("wave9", "No plan or workout exists yet. The athlete is just saying hello."),
    tools: SERVED_TOOLSETS.wave9,
    messages: [{ role: "user", content: "Hi! Just checking in - no plan needed today." }],
    roundIndex: 0,
  });

  if (!Array.isArray(blocks) || blocks.length === 0) {
    throw new Error(`${id}: provider returned no content blocks`);
  }
  const usable = blocks.some(
    (block) =>
      (block.type === "text" && typeof block.text === "string" && block.text.trim().length > 0) ||
      (block.type === "tool_use" && typeof block.name === "string")
  );
  if (!usable) {
    throw new Error(`${id}: provider returned no usable text or tool_use block: ${JSON.stringify(blocks)}`);
  }
  console.log(`  ✓ ${id} (${provider.model}) completed a live round-trip: ${blocks.length} block(s)`);
}

async function main() {
  console.log(`Smoking ${PROVIDERS.length} provider(s) with the wave9 toolset…`);
  const failures = [];
  for (const provider of PROVIDERS) {
    try {
      await smokeProvider(provider);
    } catch (error) {
      console.error(`  ✗ ${provider.id}: ${error.message}`);
      failures.push(provider.id);
    }
  }
  if (failures.length > 0) {
    console.error(`\nConversation smoke failed for: ${failures.join(", ")}. Do not merge.`);
    process.exit(1);
  }
  console.log("All providers completed a live conversation round-trip.");
}

main().catch((error) => {
  console.error("Smoke test crashed:", error);
  process.exit(1);
});
