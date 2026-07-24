// The conversation provider-failure classifier. A "capacity" verdict is what turns the app's error
// bubble into a retryable "coach is busy - your message is saved" affordance, so misclassifying a
// transient overload/rate-limit/credit failure as generic silently drops the retry path the athlete
// needs. Mirrors the credit-exhaustion signal in scripts/provider-outage.js.
const test = require("node:test");
const assert = require("node:assert/strict");

const {
  classifyProviderFailure,
  providerCapacityErrorDetails,
  PROVIDER_CAPACITY_REASON,
} = require("../lib/providerErrors");

// A minimal stand-in for the Anthropic SDK's thrown APIError: a status plus a parsed body.
function apiError(status, message) {
  return { status, message: `${status} ${message}`, error: { type: "error", error: { type: "invalid_request_error", message } } };
}

test("a 429 rate limit is a capacity failure", () => {
  assert.equal(classifyProviderFailure(apiError(429, "rate limit exceeded")), "capacity");
});

test("a 529 overload is a capacity failure", () => {
  assert.equal(classifyProviderFailure(apiError(529, "the model is overloaded")), "capacity");
});

test("a 400 credit-exhaustion rejection is a capacity failure", () => {
  const body = "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing.";
  assert.equal(classifyProviderFailure(apiError(400, body)), "capacity");
});

test("the SDK's status-prefixed message form still classifies as capacity", () => {
  const raw = {
    status: 400,
    message:
      '400 {"type":"error","error":{"type":"invalid_request_error","message":"Your credit ' +
      'balance is too low to access the Anthropic API."}}',
  };
  assert.equal(classifyProviderFailure(raw), "capacity");
});

test("a 400 schema rejection is NOT capacity - it must not be disguised as retryable", () => {
  const body = "tools.0.custom.input_schema: JSON schema is invalid. oneOf is not permitted at the top level.";
  assert.equal(classifyProviderFailure(apiError(400, body)), "other");
});

test("a 500 provider fault is not capacity", () => {
  assert.equal(classifyProviderFailure(apiError(500, "internal server error")), "other");
});

test("a plain non-API error is not capacity", () => {
  assert.equal(classifyProviderFailure(new Error("socket hang up")), "other");
  assert.equal(classifyProviderFailure(undefined), "other");
});

test("the capacity details carry the reason the app keys off", () => {
  assert.deepEqual(providerCapacityErrorDetails(), { reason: PROVIDER_CAPACITY_REASON });
  assert.equal(PROVIDER_CAPACITY_REASON, "provider_capacity");
});
