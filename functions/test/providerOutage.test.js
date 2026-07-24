// The billing-outage classifier the live-provider CI scripts share (scripts/provider-outage.js).
//
// Anthropic reports an exhausted credit balance with the same HTTP 400 invalid_request_error a
// schema rejection uses; only the message distinguishes them. Misclassifying either direction is
// costly: billing→rejection fails the paid provider-live-guard run with "fix the schema" (the
// 2026-07 CI failure), rejection→billing lets a provider-rejected schema reach a green build.
const test = require("node:test");
const assert = require("node:assert/strict");

const { isCreditExhaustion } = require("../scripts/provider-outage");

test("matches Anthropic's real credit-exhaustion error body", () => {
  const body =
    '{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is ' +
    'too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase ' +
    'credits."},"request_id":"req_011CdKMJedE7nEdgPkhZ6cSP"}';
  assert.equal(isCreditExhaustion(body), true);
});

test("matches the SDK's thrown-error message form (status prefix + body)", () => {
  assert.equal(
    isCreditExhaustion(
      '400 {"type":"error","error":{"type":"invalid_request_error","message":"Your credit ' +
      'balance is too low to access the Anthropic API."}}'
    ),
    true,
  );
});

test("never matches a genuine schema rejection", () => {
  assert.equal(
    isCreditExhaustion(
      '{"type":"error","error":{"type":"invalid_request_error","message":"tools.0.input_schema: ' +
      'JSON schema is invalid - \'oneOf\' is not allowed at the top level"}}'
    ),
    false,
  );
});

test("never matches non-string input", () => {
  assert.equal(isCreditExhaustion(undefined), false);
  assert.equal(isCreditExhaustion(null), false);
  assert.equal(isCreditExhaustion(400), false);
});
