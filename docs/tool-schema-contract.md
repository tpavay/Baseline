# Tool-Schema Contract

The conservative JSON-Schema subset every conversational agent tool `input_schema` must stay inside, and the layered guards that make a violating schema unable to reach a green build.

## Why this exists

In 2026-07, two tools (`set_performed_set_outcome`, `add_exercise`) shipped a top-level `oneOf`.
The Anthropic API rejects that construct with a 400 **before the model runs**, and because every conversation request carries the full toolset, those two schemas took down every conversation for every user served that toolset.
PR #59 fixed the schemas and pinned "no top-level combinators"; this contract generalizes that fix so the whole failure class - *any* schema construct *any* supported provider's request validator rejects - is caught mechanically, for the current model and future ones.

## The guard layers (strongest first)

| Layer | Where | What it proves | When it runs |
|---|---|---|---|
| 1. Real-provider preflight | `functions/scripts/preflight-tool-schemas.js` | The live Anthropic API **accepts every served toolset variant** (all schema-version-gated variants, exactly as the runtime serves them, real system prompt included). Minimal `max_tokens: 1` request per variant - a schema-acceptance check, not a generation. | CI job `functions-provider-preflight` on every functions PR; `npm run preflight:providers` locally |
| 2. Offline contract lint | `functions/src/toolSchemaContract.ts` + `functions/test/toolSchemaContract.test.js` | Every served tool schema stays inside the documented safe subset (allowlist). Catches most problems in milliseconds with no network. Absorbs the PR #59 regression test. | `npm test` (so also CI job `functions-verify`) |
| 3. Cross-provider profiles | `toolSchemaContract.ts` (`ProviderSchemaProfile`) | The lint is structured per provider: enforced profiles must pass; the conservative cross-provider core reports **advisories** (latent fragility), pinned in the test. | with layer 2 |
| 4. Conversation smoke | `functions/scripts/conversation-smoke.js` | One real conversation round-trip per provider through the exact provider class the runtime uses (`AnthropicProvider.complete`) with the full wave9 toolset. | CI job `functions-provider-preflight`; `npm run smoke:conversation` locally |

The offline lint approximates the provider's validator; the preflight *is* the provider's validator.
Keep both: the lint gives instant, explained feedback and covers providers you cannot cheaply call; the preflight is ground truth and catches anything the lint's model of the provider missed.

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

Nothing currently served violates the enforced profile; all 6 variants return 200 from the live API.

## Adding a provider

1. Implement `ConversationProvider` (`functions/src/provider.ts`).
2. Add its `ProviderSchemaProfile` to `toolSchemaContract.ts` and append it to `ENFORCED_PROFILES`.
   The advisories above tell you in advance which existing constructs its adapter must rewrite or its profile must allow.
3. Register a factory in the `PROVIDERS` table of `scripts/conversation-smoke.js`, and extend the preflight script with the provider's minimal validation call.
4. Add its API key as a repository Actions secret and wire it into the `functions-provider-preflight` job.

That is the whole procedure - "add its constraint profile + run the preflight", not "discover breakage in production".

## CI wiring, key, and cost

- CI job: `functions-provider-preflight` in `.github/workflows/ci.yml`, gated on the `changes` filter's `functions` output, feeding the single required `CI` check.
- Key: repository Actions secret `ANTHROPIC_API_KEY` - the **dev** Firebase project's key, mirrored from GCP Secret Manager (`firebase functions:secrets:access ANTHROPIC_API_KEY --project baseline-app-dev`). Rotate both together.
- The scripts **fail hard when the key is missing** rather than skipping: a skipped preflight would let a provider-rejected schema reach a green build.
- Cost per run: 6 preflight requests (1 output token each) + 1 smoke round-trip ≈ a few cents, only on PRs that touch `functions/`.

## Keeping the contract honest

- Adding or changing a tool schema: `npm test` lints it instantly; the PR's preflight run is the ground truth.
- If a legitimately needed construct fails the lint, extend the relevant profile **and** this document in the same PR, and let the preflight prove the provider accepts it.
- The advisory pin means new provider-fragile constructs require editing the snapshot test - that edit is the review hook.
