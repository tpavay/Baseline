const assert = require("node:assert/strict");
const test = require("node:test");

const { buildConversationProviderRequest, DEFAULT_CONVERSATION_MODEL } = require("../lib/provider");
const { buildSystemBlocks } = require("../lib/prompt");
const { anthropicSystemBlocks, withCacheBreakpointOnLastTool } = require("../lib/promptCaching");
const { SERVED_TOOLSETS } = require("../lib/tools");

// The static prefix (tools + persona) is ~27.7k tokens for wave9 and identical on every request;
// losing either breakpoint silently reverts that prefix from 10%-price cache reads to full input
// price on every conversation round. These tests pin the placement the live preflight validates.

test("the conversation request carries a cache breakpoint on the LAST tool", () => {
  const request = buildConversationProviderRequest(DEFAULT_CONVERSATION_MODEL, {
    system: buildSystemBlocks("wave9", "athlete state"),
    tools: SERVED_TOOLSETS.wave9,
    messages: [{ role: "user", content: "hi" }],
  });

  assert.equal(request.tools.length, SERVED_TOOLSETS.wave9.length);
  assert.deepEqual(request.tools.at(-1).cache_control, { type: "ephemeral" });
  for (const tool of request.tools.slice(0, -1)) {
    assert.equal("cache_control" in tool, false, `${tool.name}: only the last tool is a breakpoint`);
  }
});

test("the conversation request caches the static persona but never the athlete state", () => {
  const request = buildConversationProviderRequest(DEFAULT_CONVERSATION_MODEL, {
    system: buildSystemBlocks("wave9", "volatile athlete state"),
    tools: SERVED_TOOLSETS.wave9,
    messages: [{ role: "user", content: "hi" }],
  });

  assert.equal(request.system.length, 2);
  assert.deepEqual(request.system[0].cache_control, { type: "ephemeral" });
  assert.match(request.system[0].text, /^You are Baseline/);
  assert.equal("cache_control" in request.system[1], false,
    "the per-request state block after the breakpoint must stay uncached");
  assert.match(request.system[1].text, /volatile athlete state/);
});

test("a context-free request still ends its system prefix with a breakpoint", () => {
  const request = buildConversationProviderRequest(DEFAULT_CONVERSATION_MODEL, {
    system: buildSystemBlocks("legacy"),
    tools: SERVED_TOOLSETS.legacy,
    messages: [{ role: "user", content: "hi" }],
  });
  assert.equal(request.system.length, 1);
  assert.deepEqual(request.system[0].cache_control, { type: "ephemeral" });
});

test("breakpointing never mutates the shared toolset arrays", () => {
  const before = JSON.stringify(SERVED_TOOLSETS.wave9);
  buildConversationProviderRequest(DEFAULT_CONVERSATION_MODEL, {
    system: buildSystemBlocks("wave9"),
    tools: SERVED_TOOLSETS.wave9,
    messages: [],
  });
  assert.equal(JSON.stringify(SERVED_TOOLSETS.wave9), before);
});

test("a plain-string system (scripts, single-prompt imports) becomes one cached block", () => {
  assert.deepEqual(anthropicSystemBlocks("static prompt"), [
    { type: "text", text: "static prompt", cache_control: { type: "ephemeral" } },
  ]);
});

test("an empty tool list stays empty rather than inventing a breakpoint", () => {
  assert.deepEqual(withCacheBreakpointOnLastTool([]), []);
});
