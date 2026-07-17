import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getFunctions } from "firebase-admin/functions";
import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { onDocumentWritten } from "firebase-functions/v2/firestore";

import { AnthropicProvider } from "./provider";
import { buildSystem } from "./prompt";
import { TOOLS } from "./tools";
import {
  buildWorkoutImportProviderRequest,
  countParsedExercises,
  createWorkoutImportProviderClient,
  orchestrateWorkoutDocumentParse,
  parseWorkoutImportPayload,
  workoutDocumentValidationDiagnostic,
  workoutImportValidationLogFields,
  WORKOUT_IMPORT_TIMEOUT_SECONDS,
  WORKOUT_IMPORT_TOOL,
} from "./workoutImport";
import {
  parseStartWorkoutImportJobPayload,
} from "./workoutImportJobs";
import {
  WorkoutImportJobRuntime,
  WorkoutImportProvider,
  WorkoutImportProviderOutputTruncated,
} from "./workoutImportJobRuntime";
import {
  FirestoreWorkoutImportJobStore,
  WorkoutImportStoreError,
} from "./workoutImportFirestoreStore";

initializeApp();

const anthropicKey = defineSecret("ANTHROPIC_API_KEY");
const DAILY_LIMIT = 200; // per-user request cap; abuse guard, tune later
const IMPORT_DAILY_LIMIT = 25;
const IMPORT_MODEL = process.env.WORKOUT_IMPORT_MODEL || "claude-sonnet-4-5-20250929";
const ENFORCE_IMPORT_APP_CHECK = process.env.IMPORT_ENFORCE_APP_CHECK === "true";
const IMPORT_JOB_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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

/**
 * OCR text -> provider-neutral ParsedWorkoutDocument. Images never leave the device; the callable
 * receives only bounded OCR observations and returns schema-constrained data for deterministic local
 * matching and review.
 */
export const parseWorkoutImport = onCall(
  {
    secrets: [anthropicKey],
    region: "us-central1",
    cors: true,
    enforceAppCheck: ENFORCE_IMPORT_APP_CHECK,
    timeoutSeconds: WORKOUT_IMPORT_TIMEOUT_SECONDS,
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    const uid = req.auth.uid;
    const started = Date.now();
    let payload;
    try { payload = parseWorkoutImportPayload((req.data as { payload?: unknown } | undefined)?.payload); }
    catch (error) { throw new HttpsError("invalid-argument", `${error}`); }
    await enforceImportDailyLimit(uid);

    try {
      const client = createWorkoutImportProviderClient(
        (await import("@anthropic-ai/sdk")).default,
        anthropicKey.value(),
      );
      const requestDocument = async (content: string) => {
        const message = await client.messages.create(buildWorkoutImportProviderRequest(IMPORT_MODEL, content));
        const toolUse = message.content.find(
          (block) => block.type === "tool_use" && block.name === WORKOUT_IMPORT_TOOL.name,
        );
        if (!toolUse || toolUse.type !== "tool_use") throw new Error("provider returned no workout document");
        return toolUse.input;
      };
      const { document } = await orchestrateWorkoutDocumentParse(payload, requestDocument, {
        onValidationFailure: (attempt, diagnostic) => {
          logger.warn("workout_import.validation_failure", {
            uid,
            model: IMPORT_MODEL,
            ...workoutImportValidationLogFields(attempt, diagnostic),
          });
        },
      });
      logger.info("workout_import.ok", {
        uid, model: IMPORT_MODEL, appCheck: Boolean(req.app),
        observations: payload.observations.length,
        sourceImages: Math.max(...payload.observations.map((item) => item.sourceImageIndex)) + 1,
        characters: payload.observations.reduce((sum, item) => sum + item.text.length, 0),
        blocks: document.blocks.length,
        exercises: countParsedExercises(document),
        latencyMs: Date.now() - started,
      });
      return { document, model: IMPORT_MODEL };
    } catch (error) {
      logger.error("workout_import.provider_error", {
        uid,
        model: IMPORT_MODEL,
        latencyMs: Date.now() - started,
        reasonCode: workoutImportFailureCode(error),
      });
      throw new HttpsError("internal", "Baseline couldn't parse that workout right now. Try again.");
    }
  }
);

export const startWorkoutImportJob = onCall(
  {
    region: "us-central1",
    cors: true,
    enforceAppCheck: ENFORCE_IMPORT_APP_CHECK,
    timeoutSeconds: 45,
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    let payload;
    try {
      payload = parseStartWorkoutImportJobPayload(
        (req.data as { payload?: unknown } | undefined)?.payload,
      );
      return await workoutImportRuntime().start(req.auth.uid, payload, IMPORT_MODEL);
    } catch (error) {
      throw workoutImportCallableError(error);
    }
  },
);

export const getWorkoutImportJobStatus = onCall(
  { region: "us-central1", cors: true, enforceAppCheck: ENFORCE_IMPORT_APP_CHECK, timeoutSeconds: 45 },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    try {
      const command = parseJobCommand((req.data as { payload?: unknown } | undefined)?.payload);
      return await workoutImportRuntime().status(req.auth.uid, command.serverJobID);
    } catch (error) {
      throw workoutImportCallableError(error);
    }
  },
);

export const retryWorkoutImportJob = onCall(
  { region: "us-central1", cors: true, enforceAppCheck: ENFORCE_IMPORT_APP_CHECK, timeoutSeconds: 45 },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    try {
      const command = parseJobCommand((req.data as { payload?: unknown } | undefined)?.payload, true);
      if (!command.requestID) throw new HttpsError("invalid-argument", "Invalid request.");
      return await workoutImportRuntime().retry(req.auth.uid, {
        serverJobID: command.serverJobID,
        requestID: command.requestID,
      });
    } catch (error) {
      throw workoutImportCallableError(error);
    }
  },
);

export const cancelWorkoutImportJob = onCall(
  { region: "us-central1", cors: true, enforceAppCheck: ENFORCE_IMPORT_APP_CHECK, timeoutSeconds: 45 },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    try {
      const command = parseJobCommand((req.data as { payload?: unknown } | undefined)?.payload, true);
      if (!command.requestID) throw new HttpsError("invalid-argument", "Invalid request.");
      return await workoutImportRuntime().cancel(req.auth.uid, {
        serverJobID: command.serverJobID,
        requestID: command.requestID,
      });
    } catch (error) {
      throw workoutImportCallableError(error);
    }
  },
);

export const processWorkoutImportJob = onTaskDispatched<{
  serverJobID: string;
  generation: number;
  dispatchAttempt: number;
}>(
  {
    secrets: [anthropicKey],
    region: "us-central1",
    timeoutSeconds: 540,
    retryConfig: {
      maxAttempts: 12,
      minBackoffSeconds: 10,
      maxBackoffSeconds: 120,
      maxDoublings: 3,
    },
    rateLimits: { maxConcurrentDispatches: 10, maxDispatchesPerSecond: 5 },
  },
  async (req) => {
    const serverJobID = req.data?.serverJobID;
    const generation = req.data?.generation;
    const dispatchAttempt = req.data?.dispatchAttempt;
    if (typeof serverJobID !== "string" || typeof generation !== "number" ||
        !Number.isInteger(generation) || generation < 1 || typeof dispatchAttempt !== "number" ||
        !Number.isInteger(dispatchAttempt) || dispatchAttempt < 1) {
      throw new Error("invalid_job_dispatch");
    }
    const client = createWorkoutImportProviderClient(
      (await import("@anthropic-ai/sdk")).default,
      anthropicKey.value(),
    );
    await workoutImportRuntime({
      request: async (content, maxTokens) => {
        const message = await client.messages.create(
          buildWorkoutImportProviderRequest(IMPORT_MODEL, content, maxTokens),
        );
        if (message.stop_reason === "max_tokens") {
          throw new WorkoutImportProviderOutputTruncated();
        }
        const toolUse = message.content.find(
          (block) => block.type === "tool_use" && block.name === WORKOUT_IMPORT_TOOL.name,
        );
        if (!toolUse || toolUse.type !== "tool_use") throw new Error("missing_tool_output");
        return toolUse.input;
      },
    }).process(serverJobID, generation, dispatchAttempt);
  },
);

export const dispatchWorkoutImportJob = onDocumentWritten(
  {
    document: "workoutImportJobs/{jobID}",
    region: "us-central1",
    retry: true,
  },
  async (event) => {
    const jobID = event.params.jobID;
    const value = event.data?.after.data();
    if (!value || value.dispatchState !== "needsDispatch" ||
        value.status === "completed" || value.status === "failed" || value.status === "cancelled" ||
        typeof value.generation !== "number" || !Number.isInteger(value.generation)) {
      return;
    }
    await workoutImportRuntime().dispatch(jobID, value.generation);
  },
);

function workoutImportRuntime(provider: WorkoutImportProvider = {
  request: async () => { throw new Error("provider_unavailable"); },
}): WorkoutImportJobRuntime {
  return new WorkoutImportJobRuntime({
    store: new FirestoreWorkoutImportJobStore(getFirestore(), IMPORT_DAILY_LIMIT),
    queue: {
      enqueue: async (payload, deterministicID) => {
        try {
          await getFunctions().taskQueue("processWorkoutImportJob").enqueue(
            payload,
            { id: deterministicID, dispatchDeadlineSeconds: 540 },
          );
        } catch (error) {
          if ((error as { code?: string }).code !== "functions/task-already-exists") throw error;
        }
      },
    },
    provider,
    logger: {
      info: (event, fields) => logger.info(event, fields),
      warn: (event, fields) => logger.warn(event, fields),
    },
  });
}

function workoutImportCallableError(error: unknown): HttpsError {
  if (error instanceof HttpsError) return error;
  if (error instanceof WorkoutImportStoreError) {
    switch (error.code) {
    case "not-found": return new HttpsError("not-found", "Import job not found.");
    case "permission-denied": return new HttpsError("permission-denied", "Import job not found.");
    case "already-exists": return new HttpsError("already-exists", "That import identifier is already in use.");
    case "resource-exhausted":
      return new HttpsError("resource-exhausted", "You've hit today's workout import limit. Try again tomorrow.");
    case "failed-precondition":
      return new HttpsError("failed-precondition", "This saved import uses an incompatible schema.");
    }
  }
  if (error instanceof Error && (
    error.message === "schema_version_unsupported" ||
    error.message.includes("payload") ||
    error.message.includes("section") ||
    error.message.includes("observation") ||
    error.message.includes("provenance") ||
    error.message.includes("continuation")
  )) {
    return error.message === "schema_version_unsupported"
      ? new HttpsError("failed-precondition", "This import request uses an incompatible schema.")
      : new HttpsError("invalid-argument", error.message);
  }
  logger.error("workout_import_job.callable_error", { reasonCode: workoutImportFailureCode(error) });
  return new HttpsError("internal", "Baseline couldn't start that import right now. Try again.");
}

function parseJobCommand(raw: unknown, requireRequestID = false): {
  serverJobID: string;
  requestID?: string;
} {
  let value = raw;
  if (typeof value === "string") {
    try { value = JSON.parse(value); } catch { throw new HttpsError("invalid-argument", "Invalid request."); }
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpsError("invalid-argument", "Invalid request.");
  }
  const command = value as Record<string, unknown>;
  if (typeof command.serverJobID !== "string" || !IMPORT_JOB_ID.test(command.serverJobID) ||
      (requireRequestID &&
        (typeof command.requestID !== "string" || !IMPORT_JOB_ID.test(command.requestID)))) {
    throw new HttpsError("invalid-argument", "Invalid request.");
  }
  return {
    serverJobID: command.serverJobID.slice(0, 100),
    ...(typeof command.requestID === "string" ? { requestID: command.requestID.slice(0, 100) } : {}),
  };
}
function workoutImportFailureCode(error: unknown): string {
  if (error instanceof HttpsError) return error.code;
  const validationDiagnostic = workoutDocumentValidationDiagnostic(error);
  if (validationDiagnostic) return `invalid-structured-output:${validationDiagnostic.code}`;
  if (!(error instanceof Error)) return "unknown-failure";
  if (error.message === "provider returned no workout document") return "missing-tool-output";
  if (error.message.startsWith("parser ")) return "invalid-structured-output";
  return "provider-or-runtime-failure";
}

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

async function enforceImportDailyLimit(uid: string): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  const ref = getFirestore().doc(`users/${uid}/usage/${day}`);
  const count = await getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const next = ((snap.data()?.workoutImports as number) ?? 0) + 1;
    tx.set(ref, { workoutImports: next, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    return next;
  });
  if (count > IMPORT_DAILY_LIMIT) {
    throw new HttpsError("resource-exhausted", "You've hit today's workout import limit. Try again tomorrow.");
  }
}
