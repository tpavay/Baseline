import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { AnthropicProvider } from "./provider";
import { buildSystem } from "./prompt";
import { TOOLS } from "./tools";

initializeApp();

const anthropicKey = defineSecret("ANTHROPIC_API_KEY");
const DAILY_LIMIT = 200; // per-user request cap; abuse guard, tune later

/**
 * The **Conversation Runtime** — a thin, secure proxy between the app and the LLM. It never touches
 * Baseline's state: it adds the system prompt + tool schemas + provider key, and returns the model's
 * content blocks (text + tool_use). The app executes tool_use locally via AgentTools and resends
 * tool_results — the tool loop and state live on-device where truth lives.
 *
 * Request  : { messages: AnthropicMessage[], contextSummary?: string }
 * Response : { content: ContentBlock[] }
 */
export const conversation = onCall(
  { secrets: [anthropicKey], region: "us-central1", cors: true },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    const uid = req.auth.uid;

    const data = (req.data ?? {}) as { messages?: unknown; contextSummary?: unknown };
    // The app sends the heterogeneous transcript as a JSON string (Sendable across Swift's callable).
    let messages: unknown = data.messages;
    if (typeof messages === "string") {
      try { messages = JSON.parse(messages); } catch { throw new HttpsError("invalid-argument", "messages must be valid JSON."); }
    }
    if (!Array.isArray(messages) || messages.length === 0) {
      throw new HttpsError("invalid-argument", "messages must be a non-empty array.");
    }
    const contextSummary = typeof data.contextSummary === "string" ? data.contextSummary : undefined;

    await enforceDailyLimit(uid);

    try {
      const provider = new AnthropicProvider(anthropicKey.value(), process.env.CONVERSATION_MODEL);
      const content = await provider.complete({
        system: buildSystem(contextSummary),
        tools: TOOLS,
        messages: messages,
      });
      logger.info("conversation.ok", { uid, turns: (messages as unknown[]).length, blocks: content.length });
      return { content };
    } catch (err) {
      logger.error("conversation.provider_error", { uid, error: `${err}` });
      throw new HttpsError("internal", "Baseline couldn't reach the coach right now. Try again.");
    }
  }
);

/** Simple per-user, per-day request counter in Firestore (admin bypasses security rules). */
async function enforceDailyLimit(uid: string): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  const ref = getFirestore().doc(`users/${uid}/usage/${day}`);
  const count = await getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const next = ((snap.data()?.count as number) ?? 0) + 1;
    tx.set(ref, { count: next, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    return next;
  });
  if (count > DAILY_LIMIT) {
    throw new HttpsError("resource-exhausted", "You've hit today's chat limit. Back tomorrow.");
  }
}
