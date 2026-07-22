const assert = require("node:assert/strict");
const test = require("node:test");

const {
  conversationPromptVersion,
  conversationToolSchemaVersion,
  maskLangfuseData,
  normalizeTraceID,
  parseClientToolObservations,
} = require("../lib/llmObservability");
const { servedToolsetForClientSchema } = require("../lib/tools");

test("conversation traces record the toolset the model actually saw", () => {
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema("6")),
    "conversation-tools-v2-wave6",
  );
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema("5")),
    "conversation-tools-v2-wave5",
  );
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema(undefined)),
    "conversation-tools-v2-legacy",
  );
});

test("conversation traces record the prompt variant the model actually saw", () => {
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema("6")),
    "conversation-prompt-v3-wave6",
  );
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema("5")),
    "conversation-prompt-v3-wave5",
  );
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema(undefined)),
    "conversation-prompt-v3-legacy",
  );
});

test("normalizes UUID correlation identifiers into W3C trace IDs", () => {
  assert.equal(
    normalizeTraceID("5D7D820E-6C0A-4D94-A3EC-9D0D98ED7E95"),
    "5d7d820e6c0a4d94a3ec9d0d98ed7e95",
  );
  assert.match(normalizeTraceID("external-correlation"), /^[0-9a-f]{32}$/);
});

test("export masking retains allowlisted dimensions and redacts free text", () => {
  const masked = JSON.parse(maskLangfuseData(JSON.stringify({
    surface: "chat.today",
    model: "claude-sonnet-4-5-20250929",
    terminal_outcome: "success",
    title: "Private workout title",
    note: "My knee hurts today",
    output: "raw assistant response",
    restingHeartRate: 42,
    duration_ms: 42,
  })));

  assert.equal(masked.surface, "chat.today");
  assert.equal(masked.model, "claude-sonnet-4-5-20250929");
  assert.equal(masked.terminal_outcome, "success");
  assert.equal(masked.duration_ms, 42);
  assert.equal(masked.title, "[REDACTED]");
  assert.equal(masked.note, "[REDACTED]");
  assert.equal(masked.output, "[REDACTED]");
  assert.equal(masked.restingHeartRate, "[REDACTED]");
});

test("client tool envelopes keep structural summaries but reject content", () => {
  const parsed = parseClientToolObservations([{
    toolUseID: "tool_123",
    name: "set_checkin",
    roundIndex: 1,
    requestedOrder: 0,
    argumentSummary: {
      argumentCount: 2,
      valueTypeCounts: { number: 1, string: 1 },
      leakedText: "right knee pain",
      leakedHeartRate: 172,
    },
    argumentHash: "a".repeat(64),
    decodeResult: "passed",
    permissionResult: "passed",
    resultCategory: "completed",
    resultSummary: { textBytes: 25, rawText: "Saved right knee pain" },
    resultHash: "b".repeat(64),
    decodeMilliseconds: 1.5,
    permissionMilliseconds: 0.25,
    executionMilliseconds: 10.75,
    durationMilliseconds: 12.5,
    readOnly: false,
  }]);

  assert.equal(parsed.length, 1);
  assert.deepEqual(parsed[0].argumentSummary, {
    content_capture: "none",
    argument_count: 2,
    value_type_counts: { string: 1, number: 1 },
  });
  assert.deepEqual(parsed[0].resultSummary, {
    content_capture: "none",
    text_bytes: 25,
    has_decision: false,
    has_plan: false,
  });
});
