// Classifies a conversation provider failure so the callable can tell the app whether the coach is
// momentarily over capacity (retryable) or genuinely broken. The app maps the "capacity" verdict to
// a "coach is busy - your message is saved, tap to try again" bubble with a real retry button, and
// everything else to the generic failure copy.
//
// The credit-exhaustion signal is deliberately identical to the CI-side twin in
// scripts/provider-outage.js: Anthropic reports a drained billing account as an HTTP 400
// invalid_request_error whose ONLY discriminator from a schema rejection is the message text. Keep
// the pattern here in sync with that file.

/** Transient capacity (overload, rate limit, exhausted credits) versus any other provider failure. */
export type ProviderFailureKind = "capacity" | "other";

/** The reason code stamped into the callable error details for a capacity failure. Kept in sync with
 * `ConversationService.providerCapacityReason` on the client. */
export const PROVIDER_CAPACITY_REASON = "provider_capacity";

// Narrow on purpose: only the provider's own billing message matches, never a schema validation
// message (those name the offending field or construct). Mirrors provider-outage.js.
const CREDIT_EXHAUSTION_PATTERN = /credit balance is too low/i;

/**
 * A capacity failure is one the athlete can reasonably retry in a moment:
 *  - HTTP 429: rate limited.
 *  - HTTP 529: the model is temporarily overloaded.
 *  - HTTP 400 whose message is Anthropic's credit-exhaustion rejection (a billing outage, not a
 *    request defect) - the same text scripts/provider-outage.js keys on.
 */
export function classifyProviderFailure(error: unknown): ProviderFailureKind {
  const status = providerStatus(error);
  if (status === 429 || status === 529) return "capacity";
  if (status === 400 && CREDIT_EXHAUSTION_PATTERN.test(providerMessage(error))) return "capacity";
  return "other";
}

/** The details payload attached to a capacity `HttpsError` so the app can pick the transient copy. */
export function providerCapacityErrorDetails(): { reason: string } {
  return { reason: PROVIDER_CAPACITY_REASON };
}

/** The HTTP status the Anthropic SDK attaches to a thrown `APIError`, when present. */
function providerStatus(error: unknown): number | undefined {
  if (error && typeof error === "object" && "status" in error) {
    const status = (error as { status?: unknown }).status;
    if (typeof status === "number") return status;
  }
  return undefined;
}

/** Gathers every message-bearing field of a provider error into one string to test against. The SDK
 * surfaces the provider's text on `.message` and again in the parsed `.error` body. */
function providerMessage(error: unknown): string {
  if (!error || typeof error !== "object") return typeof error === "string" ? error : "";
  const parts: string[] = [];
  const top = (error as { message?: unknown }).message;
  if (typeof top === "string") parts.push(top);
  const body = (error as { error?: unknown }).error;
  if (body && typeof body === "object") {
    const bodyMessage = (body as { message?: unknown }).message;
    if (typeof bodyMessage === "string") parts.push(bodyMessage);
    const inner = (body as { error?: unknown }).error;
    if (inner && typeof inner === "object") {
      const innerMessage = (inner as { message?: unknown }).message;
      if (typeof innerMessage === "string") parts.push(innerMessage);
    }
  }
  return parts.join(" ");
}
