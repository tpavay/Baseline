const assert = require("node:assert/strict");
const test = require("node:test");

const fixture = require("../src/toolSchemaTokens.json");
const {
  TOOL_SCHEMA_TOKEN_FIXTURE_MODEL,
  conversationToolSchemaTokens,
  importToolSchemaTokens,
} = require("../lib/toolSchemaTokens");
const { SERVED_TOOLSETS } = require("../lib/tools");
const { DEFAULT_CONVERSATION_MODEL } = require("../lib/provider");

// The fixture is measured against the live tokenizer by scripts/measure-tool-schema-tokens.js and
// verified in CI; these tests pin the offline contract between the fixture and what the runtime
// records as tool_schema_tokens on every generation.

test("every served toolset has a measured, plausible token cost the runtime can record", () => {
  for (const [toolsetName, tools] of Object.entries(SERVED_TOOLSETS)) {
    const measured = fixture.conversation[toolsetName];
    assert.ok(measured, `${toolsetName}: missing from src/toolSchemaTokens.json - run npm run tokens:measure`);
    assert.equal(measured.toolCount, tools.length,
      `${toolsetName}: fixture measured ${measured.toolCount} tools but the runtime serves ${tools.length} - stale fixture`);
    assert.equal(conversationToolSchemaTokens(toolsetName), measured.toolSchemaTokens);
    assert.ok(Number.isInteger(measured.toolSchemaTokens) && measured.toolSchemaTokens > 0);
    assert.ok(measured.promptWithToolsTokens === measured.promptTokens + measured.toolSchemaTokens);
  }
});

test("richer toolsets cost monotonically more schema tokens", () => {
  const order = ["legacy", "wave5", "wave6", "wave7", "wave8", "wave9", "wave10"];
  for (let index = 1; index < order.length; index += 1) {
    assert.ok(
      conversationToolSchemaTokens(order[index]) > conversationToolSchemaTokens(order[index - 1]),
      `${order[index]} should cost more than ${order[index - 1]}`,
    );
  }
});

test("both workout-import request shapes have measured token costs", () => {
  for (const kind of ["durable", "sketch"]) {
    assert.equal(importToolSchemaTokens(kind), fixture.import[kind].toolSchemaTokens);
    assert.ok(importToolSchemaTokens(kind) > 0);
  }
});

test("the fixture is measured against the model the runtime defaults to", () => {
  assert.equal(TOOL_SCHEMA_TOKEN_FIXTURE_MODEL, DEFAULT_CONVERSATION_MODEL);
});

test("the per-tool attribution table covers exactly the richest toolset", () => {
  const names = Object.keys(fixture.conversationTools).sort();
  const served = SERVED_TOOLSETS.wave10.map((tool) => tool.name).sort();
  assert.deepEqual(names, served);
  for (const marginal of Object.values(fixture.conversationTools)) {
    assert.ok(Number.isInteger(marginal) && marginal > 0);
  }
});
