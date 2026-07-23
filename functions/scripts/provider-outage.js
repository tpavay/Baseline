// Shared by the live-provider CI scripts (preflight, conversation smoke, token-fixture check).
//
// Anthropic reports an exhausted credit balance as HTTP 400 `invalid_request_error` - the same
// status and error type a genuine schema rejection uses - so the only discriminator is the
// message. The distinction matters: a schema rejection is caused by this repo's code and must
// block the merge, while a drained billing account is an infrastructure outage that carries zero
// signal about schema validity and would otherwise block every functions PR with the misdiagnosis
// "fix the schema". The scripts treat the billing outage as a loudly-annotated skip instead
// (2026-07: a zero-balance key failed all 6 variants with "credit balance is too low").
"use strict";

// Deliberately narrow: only the provider's own billing message matches, never a schema
// validation message (those name the offending field/construct).
const CREDIT_EXHAUSTION_PATTERN = /credit balance is too low/i;

/** True when the provider error text is Anthropic's credit-exhaustion rejection. */
function isCreditExhaustion(errorText) {
  return typeof errorText === "string" && CREDIT_EXHAUSTION_PATTERN.test(errorText);
}

/**
 * Emit a GitHub Actions warning annotation (visible on the PR checks page) plus a plain log line,
 * so the skip is loud in CI and readable locally.
 */
function warnProviderOutage(checkName) {
  const message =
    `${checkName} could NOT run: the Anthropic API key's credit balance is exhausted. ` +
    "This is a billing outage, not a schema verdict - the served schemas are UNVERIFIED by this " +
    "run. Top up the account behind the ANTHROPIC_API_KEY repository secret and re-run the job " +
    "to restore the live-provider guarantee.";
  console.log(`::warning title=Provider billing outage - ${checkName} skipped::${message}`);
  console.error(`\nWARNING: ${message}`);
}

module.exports = { isCreditExhaustion, warnProviderOutage };
