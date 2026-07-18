import Anthropic from "@anthropic-ai/sdk";

import { withLLMGeneration } from "./llmObservability";

/** A content block returned to the app: assistant text or a tool_use the app must execute. */
export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_use"; id: string; name: string; input: Record<string, unknown> };

export interface CompleteRequest {
  system: string;
  tools: unknown[];
  messages: unknown[]; // Anthropic-format messages, passed through from the app
  roundIndex?: number;
}

/**
 * Provider-agnostic seam (the "Conversation Runtime"). Swapping to OpenAI/Gemini later is a new
 * implementation of this interface — nothing else changes.
 */
export interface ConversationProvider {
  complete(req: CompleteRequest): Promise<ContentBlock[]>;
}

export class AnthropicProvider implements ConversationProvider {
  private client: Anthropic;
  readonly model: string;

  constructor(apiKey: string, model?: string) {
    this.client = new Anthropic({ apiKey });
    // Set CONVERSATION_MODEL to a valid current model id for your account.
    this.model = model || "claude-sonnet-4-5-20250929";
  }

  async complete(req: CompleteRequest): Promise<ContentBlock[]> {
    const request = {
      model: this.model,
      max_tokens: 1024,
      system: req.system,
      tools: req.tools as Anthropic.Tool[],
      messages: req.messages as Anthropic.MessageParam[],
    };
    const msg = await withLLMGeneration({
      name: "llm.generation",
      model: this.model,
      maxTokens: request.max_tokens,
      toolChoice: "auto",
      requestContent: JSON.stringify({ system: request.system, messages: request.messages }),
      messageCount: request.messages.length,
      toolSchemaBytes: Buffer.byteLength(JSON.stringify(request.tools), "utf8"),
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
