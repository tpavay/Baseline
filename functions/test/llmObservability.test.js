const assert = require("node:assert/strict");
const test = require("node:test");

const {
  conversationPromptVersion,
  conversationToolSchemaVersion,
  maskLangfuseData,
  normalizeTraceID,
  parseClientToolObservations,
  providerErrorDetail,
} = require("../lib/llmObservability");
const { servedToolsetForClientSchema } = require("../lib/tools");

test("conversation traces record the toolset the model actually saw", () => {
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema("10")),
    "conversation-tools-v9-wave10",
  );
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema("9")),
    "conversation-tools-v9-wave9",
  );
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema("8")),
    "conversation-tools-v9-wave8",
  );
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema("7")),
    "conversation-tools-v9-wave7",
  );
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema("6")),
    "conversation-tools-v9-wave6",
  );
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema("5")),
    "conversation-tools-v9-wave5",
  );
  assert.equal(
    conversationToolSchemaVersion(servedToolsetForClientSchema(undefined)),
    "conversation-tools-v9-legacy",
  );
});

test("conversation traces record the prompt variant the model actually saw", () => {
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema("10")),
    "conversation-prompt-v6-wave10",
  );
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema("9")),
    "conversation-prompt-v6-wave9",
  );
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema("8")),
    "conversation-prompt-v6-wave8",
  );
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema("7")),
    "conversation-prompt-v6-wave7",
  );
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema("6")),
    "conversation-prompt-v6-wave6",
  );
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema("5")),
    "conversation-prompt-v6-wave5",
  );
  assert.equal(
    conversationPromptVersion(servedToolsetForClientSchema(undefined)),
    "conversation-prompt-v6-legacy",
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

// The 2026-07 top-level-oneOf outage would have shown a 100% provider_failed cliff in Langfuse
// without the WHY: only the error class name was recorded. providerErrorDetail captures the
// provider's structured error type and a bounded, charset-collapsed slice of its message - which
// must then survive the export masker, or the whole point is lost to [REDACTED].
test("a simulated Anthropic 400 yields bounded provider error detail that survives the masker", () => {
  // @anthropic-ai/sdk APIError.error is the parsed body envelope.
  const detail = providerErrorDetail({
    status: 400,
    error: {
      type: "error",
      error: {
        type: "invalid_request_error",
        message: "tools.0.custom.input_schema: oneOf is not supported at the root",
      },
    },
  });

  assert.equal(detail.code, "invalid_request_error");
  assert.equal(detail.message, "tools.0.custom.input_schema:_oneOf_is_not_supported_at_the_root");

  const masked = JSON.parse(maskLangfuseData(JSON.stringify({
    provider_error_code: detail.code,
    provider_error_message: detail.message,
    tool_schema_tokens: 22213,
  })));
  assert.equal(masked.provider_error_code, "invalid_request_error");
  assert.equal(masked.provider_error_message, detail.message);
  assert.equal(masked.tool_schema_tokens, 22213);
});

test("provider error messages are hard-capped and collapsed to the safe charset", () => {
  const { message } = providerErrorDetail({
    error: { type: "error", error: { type: "invalid_request_error", message: `"x" ${"y".repeat(500)}` } },
  });
  assert.ok(message.length <= 200);
  assert.match(message, /^[a-z0-9_./:@+-]{1,200}$/i, "must satisfy the masker's safeCode charset");

  const masked = JSON.parse(maskLangfuseData(JSON.stringify({ provider_error_message: message })));
  assert.equal(masked.provider_error_message, message);
});

test("errors without a structured provider body record nothing rather than inventing detail", () => {
  assert.deepEqual(providerErrorDetail(new Error("socket hang up")), {});
  assert.deepEqual(providerErrorDetail(undefined), {});
  // The envelope's own type: "error" marker is not a provider error code.
  assert.deepEqual(providerErrorDetail({ error: { type: "error" } }), {});
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
