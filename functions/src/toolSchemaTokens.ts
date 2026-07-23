import fixture from "./toolSchemaTokens.json";

import type { ServedToolset } from "./tools";

/**
 * Token costs of the static tool schemas, measured against the live provider's tokenizer.
 *
 * `tool_schema_bytes` is recorded per generation but bytes are not tokens: the wave9 toolset is
 * 75,770 bytes and 22,213 input tokens. These numbers are static per (toolset, model), so they are
 * NOT measured per request. `scripts/measure-tool-schema-tokens.js` counts them with Anthropic's
 * free `count_tokens` endpoint and writes the committed fixture `toolSchemaTokens.json`; the CI
 * provider-preflight job verifies the fixture matches live counts on every functions PR, so a PR
 * that fattens a schema shows up as a fixture diff ("this PR added N tokens to every request") at
 * review time.
 *
 * Each generation records its toolset's total as `tool_schema_tokens` next to `tool_schema_bytes`
 * (llmObservability.ts), which lets input tokens decompose into schema / prompt / conversation in
 * any Langfuse query. The per-toolset totals are measured as count(prompt + tools) −
 * count(prompt), so they include Anthropic's fixed ~500-token tool-use system overhead once; the
 * per-tool table in the fixture carries the same overhead in every row and is for relative
 * attribution, not summation.
 *
 * The fixture is measured against `fixture.model`. Overriding the runtime model via env config
 * changes real token counts only marginally (same tokenizer family); the recorded value stays a
 * deliberate approximation keyed by the fixture, never a per-request API call.
 */
interface ToolsetTokenCosts {
  toolCount: number;
  promptTokens: number;
  promptWithToolsTokens: number;
  toolSchemaTokens: number;
}

const conversationCosts: Record<string, ToolsetTokenCosts> = fixture.conversation;
const importCosts: Record<string, ToolsetTokenCosts> = fixture.import;

export const TOOL_SCHEMA_TOKEN_FIXTURE_MODEL: string = fixture.model;

/** The measured schema token cost of one served conversation toolset. */
export function conversationToolSchemaTokens(toolset: ServedToolset): number | undefined {
  return conversationCosts[toolset]?.toolSchemaTokens;
}

/** The measured schema token cost of one workout-import request shape. */
export function importToolSchemaTokens(kind: "durable" | "sketch"): number | undefined {
  return importCosts[kind]?.toolSchemaTokens;
}
