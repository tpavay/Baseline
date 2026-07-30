# Tool-Schema Contract

The conservative JSON-Schema subset every conversational agent tool `input_schema` must stay inside, and the layered guards that make a violating schema unable to reach a green build.

## Why this exists

In 2026-07, two tools (`set_performed_set_outcome`, `add_exercise`) shipped a top-level `oneOf`.
The Anthropic API rejects that construct with a 400 **before the model runs**, and because every conversation request carries the full toolset, those two schemas took down every conversation for every user served that toolset.
PR #59 fixed the schemas and pinned "no top-level combinators"; this contract generalizes that fix so the whole failure class - *any* schema construct *any* supported provider's request validator rejects - is caught mechanically, for the current model and future ones.

## The guard layers (strongest first)

| Layer | Where | What it proves | When it runs |
|---|---|---|---|
| 1. Real-provider preflight | `functions/scripts/preflight-tool-schemas.js` | The live Anthropic API **accepts every served toolset variant** (all schema-version-gated variants, exactly as the runtime serves them, real system prompt included). Minimal `max_tokens: 1` request per variant - a schema-acceptance check, not a generation. | **Paid, gated** - CI workflow `provider-live-guard.yml` (manual dispatch, weekly schedule, or a PR labeled `provider-smoke`); `npm run preflight:providers` locally. **Not on every PR.** |
| 2. Offline contract lint | `functions/src/toolSchemaContract.ts` + `functions/test/toolSchemaContract.test.js` | Every served tool schema stays inside the documented safe subset (allowlist). Catches most problems in milliseconds with no network. Absorbs the PR #59 regression test. **This is the per-PR provider-rejection guard.** | `npm test` (so also CI job `functions-verify`) - every functions PR, **$0** |
| 3. Cross-provider profiles | `toolSchemaContract.ts` (`ProviderSchemaProfile`) | The lint is structured per provider: enforced profiles must pass; the conservative cross-provider core reports **advisories** (latent fragility), pinned in the test. | with layer 2 |
| 4. Conversation smoke | `functions/scripts/conversation-smoke.js` | One real conversation round-trip per provider through the exact provider class the runtime uses (`AnthropicProvider.complete`) with the current richest served toolset, Wave 10. | **Paid, gated** - CI workflow `provider-live-guard.yml` (same triggers as layer 1); `npm run smoke:conversation` locally. **Not on every PR.** |
| 5. Token-cost fixture | `functions/scripts/measure-tool-schema-tokens.js` + `functions/src/toolSchemaTokens.json` | The measured per-request token cost of every served toolset (recorded as `tool_schema_tokens` on each generation; see `toolSchemaTokens.ts`). Not an acceptance guard - a **cost** guard: a PR that fattens a schema must regenerate the fixture, so the token delta is a visible diff in review. | CI job `functions-token-fixture` (`npm run tokens:check`, **free** `count_tokens`) - every functions PR, **$0**; contributors regenerate through `regenerate-tool-schema-token-fixture.yml` without receiving the key |

The offline lint approximates the provider's validator; the preflight *is* the provider's validator.
Keep both: the lint gives instant, explained feedback on every PR at no cost and covers providers you cannot cheaply call; the preflight is ground truth and catches anything the lint's model of the provider missed, and it runs deliberately (dispatch / schedule / label) rather than on every PR.
The preflight submits the runtime's exact request shape - prompt-caching `cache_control` breakpoints included (`functions/src/promptCaching.ts`) - so a provider rejecting the cache placement also cannot reach a green build.

## Where each layer runs: free per-PR vs paid-and-gated

Routine CI (every PR/push) spends **$0** of real provider tokens.
The provider-rejection guarantee on the per-PR path is carried entirely by **offline/free means**:

- **Layer 2 (offline lint)** is the load-bearing per-PR acceptance guard. It runs in `functions-verify` via `npm test`, rejects top-level `oneOf`/`anyOf`/`allOf`/`not` and every construct outside the allowlist, and fails the required `CI` check with no network and no spend. A PR that reintroduces the 2026-07 top-level-`oneOf` schema fails here.
- **Layer 5 (`tokens:check`)** also runs every functions PR but is **free**: it uses Anthropic's `count_tokens` endpoint, which is not billed. It is a **cost** guard only.

The paid layers (1 real-provider preflight, 4 conversation smoke) moved **off** the per-PR path into the opt-in `provider-live-guard.yml` workflow. They run only when deliberately requested: `workflow_dispatch`, a weekly `schedule` canary, or a PR carrying the `provider-smoke` label.

### Why `count_tokens` cannot replace the paid preflight

`count_tokens` is free, so it is tempting to use it as a per-PR acceptance check. It **does not work for that** - verified against the live API on 2026-07-23:

| Endpoint | Top-level `oneOf` tool schema | Cost of that request |
|---|---|---|
| `POST /v1/messages/count_tokens` | **HTTP 200** (returns a token count; no schema validation) | free either way |
| `POST /v1/messages` | **HTTP 400** `invalid_request_error`: `input_schema does not support oneOf, allOf, or anyOf at the top level` | **$0** (a rejected request is not billed) |

So the free endpoint gives a false pass on the exact construct that took down every conversation in 2026-07.
Only the `messages` endpoint rejects it.
And a request the provider *accepts* is billed for its input tokens (roughly 148K across the 7 served variants, about $0.44/run), so proving live acceptance on every PR cannot be free.
Hence: the offline lint is the per-PR guard, and the live `messages` preflight is a gated backstop.
**Do not weaken the offline lint on the assumption that `count_tokens` (or any free check) covers acceptance - it does not.**

## The safe subset

The lint is an **allowlist**: any keyword not listed fails, so a new exotic construct cannot ship silently.

Allowed everywhere (Anthropic profile, the currently enforced one):

`type`, `properties`, `required`, `description`, `enum`, `items` (single-schema form only), `minItems`, `maxItems`, `minimum`, `maximum`, `minLength`, `maxLength`, `minProperties`, `maxProperties`, `additionalProperties` (boolean only), `dependencies` (array or schema form), and - **nested only** - `anyOf`, `oneOf`, `allOf`, `not`.

The top level of `input_schema` must be `type: "object"` and must not carry `oneOf`, `anyOf`, `allOf`, or `not`.

### Banned constructs and why

| Construct | Why it is outside the subset |
|---|---|
| Top-level `oneOf`/`anyOf`/`allOf`/`not` | Anthropic rejects the **entire request** with a 400 before the model runs - the 2026-07 outage. |
| Nested combinators on non-Anthropic providers | Gemini's proto-based `FunctionDeclaration` and OpenAI strict validators reject or ignore them; tracked as cross-provider advisories today. |
| `$ref` / `$defs` / `definitions` | Reference resolution is not guaranteed at the provider request layer; a dangling or external ref rejects the request. |
| `if` / `then` / `else` | Draft-07 conditionals with uneven provider support; impossible to preflight exhaustively. |
| `dependentSchemas` / `dependentRequired` | 2019-09 keywords with uneven support; use `dependencies` (which the Anthropic profile allows). |
| Tuple-form `items` (array of schemas) / `prefixItems` / `additionalItems` | Tuple validation is unsupported by provider function-calling validators. |
| `patternProperties` / `propertyNames` | Ignored or rejected by strict provider validators. |
| `format` (any value) | Silently ignored by some providers, rejected by others; none is currently allowlisted - extend the profile deliberately if one is needed. |
| `pattern`, `const`, `contains`, `unevaluated*` | Uneven support / differing regex dialects; not currently needed. |
| Schema-form `additionalProperties` | Uneven support; keep it boolean. |

Full rationale strings live in `RISKY_KEYWORD_RATIONALE` in `toolSchemaContract.ts`; lint failures print them.

## Cross-provider advisories (latent fragility)

Constructs the enforced Anthropic profile accepts (and the preflight proves the live API accepts) but that fall outside the conservative cross-provider core (`CROSS_PROVIDER_CORE_PROFILE`).
They are pinned in `test/toolSchemaContract.test.js` so growing the list is a conscious choice.
Current findings, from auditing the full toolset (2026-07):

| Construct | Tools | Fragility |
|---|---|---|
| Schema-form `dependencies` with nested `not` | `set_performed_set_outcome`, `add_exercise`, `upsert_performed_set`, `add_extra_performed_set` | #59's chosen mutual-exclusion encoding. OpenAI-style validators ignore it (weaker validation, not rejection); Gemini rejects unknown fields. The iOS mapper backstop enforces the exclusivity deterministically regardless. |
| `["X","null"]` type unions | `update_*` patch tools, `set_checkin`, `set_sleep`, `set_equipment`, `set_time_available` | Gemini expresses nullability as `nullable`, not a type union. A Gemini adapter would rewrite these mechanically. |
| `minProperties` | `update_*` patch tools, `bulk_replace_exercises`, `convert_workout_units` | No equivalent in Gemini's schema; would be ignored/stripped, weakening "non-empty patch" validation to the server-side mapper. |

Nothing currently served violates the enforced offline profile.
The gated live preflight covers all 7 variants.

## Adding a provider

1. Implement `ConversationProvider` (`functions/src/provider.ts`).
2. Add its `ProviderSchemaProfile` to `toolSchemaContract.ts` and append it to `ENFORCED_PROFILES`.
   The advisories above tell you in advance which existing constructs its adapter must rewrite or its profile must allow.
3. Register a factory in the `PROVIDERS` table of `scripts/conversation-smoke.js`, and extend the preflight script with the provider's minimal validation call.
4. Add its API key as a repository Actions secret and wire it into the `provider-live` job of `.github/workflows/provider-live-guard.yml`.

That is the whole procedure - "add its constraint profile + run the preflight", not "discover breakage in production".

## CI wiring, key, and cost

**Free, every functions PR** (`.github/workflows/ci.yml`, gated on the `changes` filter's `functions` output, feeding the single required `CI` check):

- `functions-verify` runs `npm test`, which includes the offline contract lint (layer 2/3) - the per-PR provider-rejection guard. **$0.**
- `functions-token-fixture` runs `npm run tokens:check` against the free `count_tokens` endpoint (layer 5, a cost guard). **$0.**

No real-provider **`messages`** request runs on the per-PR path, so routine CI spends nothing on provider tokens.

**Paid, opt-in** (`.github/workflows/provider-live-guard.yml`, the `provider-live` job - layers 1 and 4):

- Triggers: `workflow_dispatch` (manual), a weekly `schedule` canary, or a PR labeled `provider-smoke`. Never on an unlabeled PR.
- To run it on a specific PR, add the `provider-smoke` label; to run it ad hoc, dispatch the workflow from the Actions tab.
- `schedule` fires only from the default branch, so the weekly canary activates once the workflow file reaches that branch.

**Key** (all three provider-calling workflows): repository Actions secret `ANTHROPIC_API_KEY` - the **dev** Firebase project's key, mirrored from GCP Secret Manager (`firebase functions:secrets:access ANTHROPIC_API_KEY --project baseline-app-dev`). Rotate both together. (This is currently the same key as production; separating keys per environment is a follow-up.)

- The provider-calling preflight, smoke, and token-measurement modes **fail hard when the key is missing** rather than skipping.
  A skipped preflight would give a false "provider accepts these schemas" signal.
  The keyless request-shape export mode intentionally does not require or read the key.
- Contributors do not need a local copy of the key to regenerate `toolSchemaTokens.json`.
  The contributor procedure and workflow trust boundary are authoritative in `functions/scripts/README.md`.
- One deliberate exception: Anthropic reports an **exhausted credit balance** as the same HTTP 400 `invalid_request_error` a schema rejection uses, but it is a billing outage with zero schema signal, so the scripts (`scripts/provider-outage.js`) classify it apart and skip with a `::warning` annotation instead of misreporting "fix the schema".
  The schemas are unverified by such a run; top up the account behind the secret and re-run the workflow.
- Cost: the gated run is 7 preflight requests (1 output token each) plus 1 Wave 10 smoke round-trip, roughly 148K preflight input tokens and about $0.53 total. The per-PR `tokens:check` is ~90 **free** `count_tokens` requests.

## Keeping the contract honest

- Adding or changing a tool schema: `npm test` lints it instantly; the PR's preflight run is the ground truth.
  Also regenerate the token fixture with the workflow documented in `functions/scripts/README.md` or with `npm run tokens:measure` when a local key is already available, then commit the diff.
  `tokens:check` is exact, so any served-schema or system-prompt change makes the fixture stale.
- If a legitimately needed construct fails the lint, extend the relevant profile **and** this document in the same PR, and let the preflight prove the provider accepts it.
- The advisory pin means new provider-fragile constructs require editing the snapshot test - that edit is the review hook.
