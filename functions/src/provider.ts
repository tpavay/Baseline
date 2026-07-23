import Anthropic from "@anthropic-ai/sdk";

import { withLLMGeneration } from "./llmObservability";
import {
  SystemPromptBlock,
  anthropicSystemBlocks,
  withCacheBreakpointOnLastTool,
} from "./promptCaching";

/** A content block returned to the app: assistant text or a tool_use the app must execute. */
export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_use"; id: string; name: string; input: Record<string, unknown> };

export interface CompleteRequest {
  /** Ordered system blocks (static cacheable prefix, then volatile state), or one static string. */
  system: string | SystemPromptBlock[];
  tools: unknown[];
  messages: unknown[]; // Anthropic-format messages, passed through from the app
  roundIndex?: number;
  /** The served toolset's fixture-measured schema token cost (see toolSchemaTokens.ts). */
  toolSchemaTokens?: number;
}

/**
 * Provider-agnostic seam (the "Conversation Runtime"). Swapping to OpenAI/Gemini later is a new
 * implementation of this interface — nothing else changes.
 */
export interface ConversationProvider {
  complete(req: CompleteRequest): Promise<ContentBlock[]>;
}

/**
 * The model conversation requests use when CONVERSATION_MODEL is unset. Exported so the CI
 * schema preflight validates every served toolset against the exact model the runtime targets.
 */
export const DEFAULT_CONVERSATION_MODEL = "claude-sonnet-4-5-20250929";

/**
 * The exact Anthropic request one conversation round sends, with prompt-caching breakpoints on
 * the static prefix (last tool + static system block; see promptCaching.ts). Pure and exported so
 * tests pin the cache placement and the CI preflight submits this same shape to the live API.
 */
export function buildConversationProviderRequest(
  model: string,
  req: CompleteRequest,
): Anthropic.MessageCreateParamsNonStreaming {
  return {
    model,
    max_tokens: 1024,
    system: anthropicSystemBlocks(req.system),
    tools: withCacheBreakpointOnLastTool(req.tools as object[]) as Anthropic.Tool[],
    messages: req.messages as Anthropic.MessageParam[],
  };
}

export class AnthropicProvider implements ConversationProvider {
  private client: Anthropic;
  readonly model: string;

  constructor(apiKey: string, model?: string) {
    this.client = new Anthropic({ apiKey });
    // Set CONVERSATION_MODEL to a valid current model id for your account.
    this.model = model || DEFAULT_CONVERSATION_MODEL;
  }

  async complete(req: CompleteRequest): Promise<ContentBlock[]> {
    const request = buildConversationProviderRequest(this.model, req);
    const msg = await withLLMGeneration({
      name: "llm.generation",
      model: this.model,
      maxTokens: request.max_tokens,
      toolChoice: "auto",
      requestContent: JSON.stringify({ system: request.system, messages: request.messages }),
      messageCount: request.messages.length,
      toolSchemaBytes: Buffer.byteLength(JSON.stringify(request.tools), "utf8"),
      toolSchemaTokens: req.toolSchemaTokens,
      callIndex: req.roundIndex,
      roundIndex: req.roundIndex,
    }, () => this.client.messages.create(request));
    return msg.content.map((b) => {
      if (b.type === "text") return { type: "text", text: b.text };
      if (b.type === "tool_use") {
        return { type: "tool_use", id: b.id, name: b.name, input: (b.input ?? {}) as Record<string, unknown> };
      }
      return { type: "text", text: "" };
    });
  }
}
