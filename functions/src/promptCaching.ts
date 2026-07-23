/**
 * Anthropic prompt-caching request shaping.
 *
 * Every conversation request re-sends an identical static prefix - the system prompt plus the
 * full served toolset (~27.7k tokens for wave9) - and every workout-import request re-sends its
 * static system prompt and tool schema. Anthropic caches everything up to and including a
 * `cache_control` breakpoint, so marking the LAST tool and the STATIC system block converts that
 * prefix to cache reads at 10% of input price after one 1.25x cache write. Volatile content (the
 * per-request athlete state block and the conversation messages) stays after the breakpoints and
 * is never cached.
 *
 * `@anthropic-ai/sdk` 0.30.1 predates the GA `cache_control` field, so its Messages types do not
 * carry it; the live API accepts it without a beta header. These helpers return structural
 * supertypes of the SDK's `TextBlockParam`/`Tool` shapes, which assign cleanly - no casts and no
 * SDK upgrade. The CI provider preflight submits this exact request shape to the live API, so a
 * provider rejecting `cache_control` cannot reach a green build.
 */

export interface AnthropicCacheControl {
  type: "ephemeral";
}

/**
 * One block of the system prompt, ordered. `cacheable` marks the block a cache breakpoint may
 * cover: static content, identical across requests for the same toolset. Volatile blocks (the
 * athlete's current state) must never be cacheable - a breakpoint after them would invalidate
 * the whole cached prefix on every state change.
 */
export interface SystemPromptBlock {
  text: string;
  cacheable: boolean;
}

export interface CacheableTextBlockParam {
  type: "text";
  text: string;
  cache_control?: AnthropicCacheControl;
}

const EPHEMERAL: AnthropicCacheControl = { type: "ephemeral" };

/**
 * The provider-request `system` array: a breakpoint on the LAST cacheable block, none on volatile
 * blocks. A plain string (used by scripts and single-prompt import requests, which are fully
 * static) becomes one cacheable block.
 */
export function anthropicSystemBlocks(
  system: string | readonly SystemPromptBlock[],
): CacheableTextBlockParam[] {
  const blocks = typeof system === "string" ? [{ text: system, cacheable: true }] : system;
  const lastCacheable = blocks.reduce(
    (last, block, index) => (block.cacheable ? index : last),
    -1,
  );
  return blocks.map((block, index) => ({
    type: "text",
    text: block.text,
    ...(index === lastCacheable ? { cache_control: EPHEMERAL } : {}),
  }));
}

/**
 * A copy of the tools array whose LAST tool carries the cache breakpoint, covering every tool
 * schema before it. Source arrays (SERVED_TOOLSETS, the import tool constants) are shared module
 * state and are never mutated.
 */
export function withCacheBreakpointOnLastTool<T extends object>(
  tools: readonly T[],
): Array<T & { cache_control?: AnthropicCacheControl }> {
  if (tools.length === 0) return [];
  return tools.map((tool, index) =>
    index === tools.length - 1 ? { ...tool, cache_control: EPHEMERAL } : { ...tool },
  );
}
