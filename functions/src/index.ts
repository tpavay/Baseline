import { onCall, onRequest, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
import { getAppCheck } from "firebase-admin/app-check";
import { getFunctions } from "firebase-admin/functions";
import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { createHash, randomUUID } from "node:crypto";

import { AnthropicProvider } from "./provider";
import { buildSystemBlocks } from "./prompt";
import { servedToolsetForClientSchema, toolsForClientSchema } from "./tools";
import { conversationToolSchemaTokens, importToolSchemaTokens } from "./toolSchemaTokens";
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
  buildWorkoutImportSketchContent,
  buildWorkoutImportSketchRequest,
  parseWorkoutImportStreamPayload,
  serverSentEvent,
  WorkoutImportStreamPayloadError,
  WORKOUT_IMPORT_SKETCH_TOOL,
  WORKOUT_IMPORT_SKETCH_TOOL_NAME,
  WORKOUT_IMPORT_SKETCH_VERSION,
  abortWhenClientDisconnects,
  emptyWorkoutImportStreamResult,
  foldWorkoutImportStreamUsage,
  workoutImportStreamTerminalOutcome,
} from "./workoutImportStream";
import {
  parseStartWorkoutImportJobPayload,
  StoredWorkoutImportJob,
} from "./workoutImportJobs";
import {
  WorkoutImportJobRuntime,
  WorkoutImportObservability,
  WorkoutImportProvider,
  WorkoutImportProviderOutputTruncated,
} from "./workoutImportJobRuntime";
import {
  FirestoreWorkoutImportJobStore,
  WorkoutImportStoreError,
} from "./workoutImportFirestoreStore";
import {
  AppTraceMetadata,
  LLM_OBSERVABILITY_VERSIONS,
  LLMSurface,
  configureLLMObservability,
  conversationPromptVersion,
  conversationToolSchemaVersion,
  flushLLMObservability,
  parseClientToolObservations,
  recordClientToolObservations,
  recordTerminalOutcome,
  recordValidatorObservation,
  shouldSampleTelemetry,
  withLLMGeneration,
  withLLMSpan,
  withLLMTrace,
} from "./llmObservability";

initializeApp();

const anthropicKey = defineSecret("ANTHROPIC_API_KEY");
const langfuseSecretKey = defineSecret("LANGFUSE_SECRET_KEY");
const langfusePublicKey = defineSecret("LANGFUSE_PUBLIC_KEY");
const langfuseBaseURL = defineSecret("LANGFUSE_BASE_URL");
const providerAndObservabilitySecrets = [
  anthropicKey,
  langfuseSecretKey,
  langfusePublicKey,
  langfuseBaseURL,
];
const DAILY_LIMIT = 200; // per-user request cap; abuse guard, tune later
const IMPORT_DAILY_LIMIT = 25;
const IMPORT_MODEL = process.env.WORKOUT_IMPORT_MODEL || "claude-sonnet-4-5-20250929";
// The fast path's model is separately overridable. It intentionally defaults to the same model as
// the durable path: the measured latency win comes from one call and a permissive schema (~3x fewer
// output tokens), not from the model tier, and switching tiers needs a corpus rather than the one
// workout the report measured.
const IMPORT_STREAM_MODEL = process.env.WORKOUT_IMPORT_STREAM_MODEL || IMPORT_MODEL;
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
  { secrets: providerAndObservabilitySecrets, region: "us-central1", cors: true },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    const uid = req.auth.uid;

    const data = (req.data ?? {}) as {
      messages?: unknown;
      contextSummary?: unknown;
      traceID?: unknown;
      sessionID?: unknown;
      surface?: unknown;
      roundIndex?: unknown;
      appVersion?: unknown;
      appBuild?: unknown;
      iosVersion?: unknown;
      deviceClass?: unknown;
      toolEvents?: unknown;
      clientToolSchemaVersion?: unknown;
    };
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
    configureObservabilityFromSecrets();
    const provider = new AnthropicProvider(anthropicKey.value(), process.env.CONVERSATION_MODEL);
    const trace = conversationTraceContext(data, uid, provider.model);

    try {
      return await withLLMTrace(`cloud_function.round.${trace.roundIndex}`, trace, async () => {
        await recordClientToolObservations(parseToolEvents(data.toolEvents));
        try {
          const servedToolset = servedToolsetForClientSchema(data.clientToolSchemaVersion);
          const content = await provider.complete({
            system: buildSystemBlocks(servedToolset, contextSummary),
            tools: toolsForClientSchema(data.clientToolSchemaVersion),
            messages: messages,
            roundIndex: trace.roundIndex,
            toolSchemaTokens: conversationToolSchemaTokens(servedToolset),
          });
          const requestedTools = content.filter((block) => block.type === "tool_use").length;
          if (requestedTools === 0) {
            await recordTerminalOutcome("success", undefined, { round_index: trace.roundIndex });
          }
          logger.info("conversation.ok", { uid, turns: (messages as unknown[]).length, blocks: content.length });
          return { content };
        } catch (error) {
          await recordTerminalOutcome("provider_failed", undefined, { round_index: trace.roundIndex });
          throw error;
        }
      });
    } catch (err) {
      logger.error("conversation.provider_error", { uid, error: `${err}` });
      throw new HttpsError("internal", "Baseline couldn't reach the coach right now. Try again.");
    } finally {
      await flushLLMObservability();
    }
  }
);

/** Accepts privacy-filtered client tool spans that cannot be attached to a later model round. */
export const recordLLMObservability = onCall(
  { secrets: [langfuseSecretKey, langfusePublicKey, langfuseBaseURL], region: "us-central1", cors: true },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    const data = (req.data ?? {}) as Record<string, unknown>;
    configureObservabilityFromSecrets();
    const model = process.env.CONVERSATION_MODEL || "claude-sonnet-4-5-20250929";
    const trace = conversationTraceContext(data, req.auth.uid, model);
    if (!shouldSampleTelemetry(trace.traceID)) {
      return { accepted: true, sampled: false };
    }
    const terminalOutcome = allowedChatTerminalOutcome(data.terminalOutcome);
    try {
      await withLLMTrace("client-telemetry", trace, async () => {
        await recordClientToolObservations(parseToolEvents(data.toolEvents));
        if (terminalOutcome) {
          await recordTerminalOutcome(terminalOutcome, undefined, { round_index: trace.roundIndex });
        }
      });
      return { accepted: true, sampled: true };
    } finally {
      await flushLLMObservability();
    }
  },
);

/**
 * OCR text -> provider-neutral ParsedWorkoutDocument. Images never leave the device; the callable
 * receives only bounded OCR observations and returns schema-constrained data for deterministic local
 * matching and review.
 */
export const parseWorkoutImport = onCall(
  {
    secrets: providerAndObservabilitySecrets,
    region: "us-central1",
    cors: true,
    enforceAppCheck: ENFORCE_IMPORT_APP_CHECK,
    timeoutSeconds: WORKOUT_IMPORT_TIMEOUT_SECONDS,
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    const uid = req.auth.uid;
    const started = Date.now();
    let payload: ReturnType<typeof parseWorkoutImportPayload>;
    try { payload = parseWorkoutImportPayload((req.data as { payload?: unknown } | undefined)?.payload); }
    catch (error) { throw new HttpsError("invalid-argument", `${error}`); }
    await enforceImportDailyLimit(uid);
    configureObservabilityFromSecrets();
    const traceID = randomUUID();
    const validationObservations: Array<Promise<void>> = [];

    try {
      return await withLLMTrace("import-legacy", {
        traceID,
        sessionID: traceID,
        surface: "import.image.legacy",
        uid,
        model: IMPORT_MODEL,
        promptVersion: LLM_OBSERVABILITY_VERSIONS.importPrompt,
        outputSchemaVersion: LLM_OBSERVABILITY_VERSIONS.importOutput,
        validatorVersion: LLM_OBSERVABILITY_VERSIONS.importValidator,
        catalogVersion: catalogFingerprint(payload.catalogHints),
      }, async () => {
        try {
        const client = createWorkoutImportProviderClient(
          (await import("@anthropic-ai/sdk")).default,
          anthropicKey.value(),
        );
        const requestDocument = async (content: string) => {
          const request = buildWorkoutImportProviderRequest(IMPORT_MODEL, content);
          const message = await withLLMGeneration({
            name: "llm.generation.initial",
            model: IMPORT_MODEL,
            maxTokens: request.max_tokens,
            temperature: request.temperature,
            toolChoice: "submit_workout_import_ir",
            requestContent: content,
            messageCount: request.messages.length,
            toolSchemaBytes: Buffer.byteLength(JSON.stringify(request.tools), "utf8"),
            toolSchemaTokens: importToolSchemaTokens("durable"),
            callIndex: 0,
            sectionIndex: 0,
            repairIndex: 0,
            providerRetryIndex: 0,
          }, () => client.messages.create(request));
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
            validationObservations.push(recordValidatorObservation({
              validatorName: "workout-import-ir",
              validatorVersion: LLM_OBSERVABILITY_VERSIONS.importValidator,
              attemptKind: attempt,
              passed: false,
              durationMilliseconds: 0,
              ruleCode: diagnostic.code,
              stage: diagnostic.boundary,
              path: diagnostic.path,
              relationshipRule: diagnostic.relationshipRule,
              observedCount: diagnostic.observedCount,
              expectedCount: diagnostic.expectedExerciseCount,
              rejectedRecordKind: diagnostic.recordKind,
              repairCount: 0,
              repairRequested: false,
              finalAction: "terminal_reject",
              relatedIdentifiers: diagnostic.relatedObservationIDs,
            }));
          },
        });
        await Promise.all(validationObservations);
        await recordValidatorObservation({
          validatorName: "workout-import-ir",
          validatorVersion: LLM_OBSERVABILITY_VERSIONS.importValidator,
          attemptKind: "initial",
          passed: true,
          durationMilliseconds: 0,
          repairCount: 0,
          repairRequested: false,
          finalAction: "accept",
        });
        await recordTerminalOutcome("success");
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
          await Promise.all(validationObservations);
          const failureCode = workoutImportFailureCode(error);
          await recordTerminalOutcome(
            failureCode.startsWith("invalid-structured-output") ? "validation_failed" : "provider_failed",
            failureCode,
          );
          throw error;
        }
      });
    } catch (error) {
      logger.error("workout_import.provider_error", {
        uid,
        model: IMPORT_MODEL,
        latencyMs: Date.now() - started,
        reasonCode: workoutImportFailureCode(error),
      });
      throw new HttpsError("internal", "Baseline couldn't parse that workout right now. Try again.");
    } finally {
      await flushLLMObservability();
    }
  }
);

/**
 * The **fast import path** — one streaming multimodal call, rendered on the device as it arrives.
 *
 * This is `onRequest` rather than `onCall` because a callable cannot stream, and streaming is the
 * whole point: the measured pipeline took 122.8 s to show the athlete anything, while one streaming
 * call put the first exercise on screen at ~4 s and finished at ~8 s. Being `onRequest` means auth
 * and App Check are verified here by hand rather than by the callable wrapper.
 *
 * The durable job (`startWorkoutImportJob`) is deliberately kept as the resumable retry when this
 * path produces no usable exercise skeleton, because it survives the app being killed and it holds
 * the transactional cost ceilings. The streaming request itself accepts the same bounded ten-photo
 * input as the client so complex multi-photo workouts avoid the rigid relationship validator first.
 *
 * Wire format: newline-delimited SSE. `{"type":"delta","text":...}` carries raw JSON fragments of
 * the tool input; `{"type":"done","model":...}` ends a good stream; `{"type":"error","code":...}`
 * ends a bad one. The client assembles and converts - see WorkoutImportSketchStream.
 */
export const streamWorkoutImport = onRequest(
  {
    secrets: providerAndObservabilitySecrets,
    region: "us-central1",
    cors: true,
    timeoutSeconds: WORKOUT_IMPORT_TIMEOUT_SECONDS,
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "method-not-allowed" });
      return;
    }
    const uid = await verifiedUID(req.get("Authorization"));
    if (!uid) {
      res.status(401).json({ error: "unauthenticated" });
      return;
    }
    if (!(await appCheckAccepted(req.get("X-Firebase-AppCheck")))) {
      res.status(401).json({ error: "app-check-failed" });
      return;
    }

    let payload: ReturnType<typeof parseWorkoutImportStreamPayload>;
    try {
      payload = parseWorkoutImportStreamPayload(req.body);
    } catch (error) {
      const code = error instanceof WorkoutImportStreamPayloadError ? error.code : "malformed_payload";
      res.status(400).json({ error: code });
      return;
    }
    try {
      await enforceImportDailyLimit(uid);
    } catch (error) {
      // Only genuine quota exhaustion is a rate limit. A Firestore outage, a permission error, or
      // transaction contention is a backend fault and is reported as one rather than being
      // disguised as the athlete having used up their day.
      if (error instanceof HttpsError && error.code === "resource-exhausted") {
        res.status(429).json({ error: "rate_limited" });
        return;
      }
      logger.error("workout_import_stream.limit_unavailable", { uid, error: `${error}` });
      res.status(503).json({ error: "remote_unavailable" });
      return;
    }

    // Past this point the response is a stream, so failures are reported inside it rather than as a
    // status code: the client has already committed to reading events.
    res.status(200);
    res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
    res.setHeader("Cache-Control", "no-cache, no-transform");
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders?.();

    configureObservabilityFromSecrets();
    const traceID = randomUUID();
    const started = Date.now();
    let deltaCount = 0;
    let characters = 0;

    // The client cancels its URLSession task when the athlete dismisses the import, so the socket
    // closing means nobody is waiting. Aborting the provider call is the other half of that: without
    // it the model keeps writing, at full output-token cost, into a response that is already gone.
    const abandoned = new AbortController();
    abortWhenClientDisconnects(res, abandoned);
    // Both halves of the race read this: the loop that notices and breaks, and the AbortError the
    // SDK throws when the signal fires first.
    const clientLeft = () => abandoned.signal.aborted || res.destroyed;
    const writable = () => !clientLeft() && !res.writableEnded;
    const usage = emptyWorkoutImportStreamResult();

    try {
      await withLLMTrace("import-stream", {
        traceID,
        sessionID: traceID,
        surface: "import.image.stream",
        uid,
        model: IMPORT_STREAM_MODEL,
        promptVersion: WORKOUT_IMPORT_SKETCH_VERSION,
        outputSchemaVersion: WORKOUT_IMPORT_SKETCH_VERSION,
        validatorVersion: "workout-import-sketch-converter-v1",
        catalogVersion: catalogFingerprint(payload.catalogHints),
      }, async () => {
        try {
        const client = createWorkoutImportProviderClient(
          (await import("@anthropic-ai/sdk")).default,
          anthropicKey.value(),
        );
        const content = buildWorkoutImportSketchContent(payload);
        const request = buildWorkoutImportSketchRequest(IMPORT_STREAM_MODEL, content);
        await withLLMGeneration({
          name: "llm.generation.sketch",
          model: IMPORT_STREAM_MODEL,
          maxTokens: request.max_tokens,
          temperature: request.temperature,
          toolChoice: WORKOUT_IMPORT_SKETCH_TOOL_NAME,
          messageCount: request.messages.length,
          toolSchemaBytes: Buffer.byteLength(JSON.stringify([WORKOUT_IMPORT_SKETCH_TOOL]), "utf8"),
          toolSchemaTokens: importToolSchemaTokens("sketch"),
          callIndex: 0,
          streaming: true,
          // The provider bills a stream it never finished, so the tokens it did consume are
          // attached even when this throws.
          partialUsage: () => usage,
        }, async () => {
          const stream = await client.messages.create(request, { signal: abandoned.signal });
          for await (const event of stream as AsyncIterable<Record<string, unknown>>) {
            if (!writable()) break;
            foldWorkoutImportStreamUsage(usage, event);
            if (event.type !== "content_block_delta") continue;
            const delta = event.delta as { type?: string; partial_json?: string } | undefined;
            if (delta?.type !== "input_json_delta" || typeof delta.partial_json !== "string") continue;
            deltaCount += 1;
            characters += delta.partial_json.length;
            if (writable()) res.write(serverSentEvent({ type: "delta", text: delta.partial_json }));
          }
          // Returned rather than discarded: this is the object the trace prices the import from.
          return usage;
        });
        // Inside the trace, like every other terminal outcome, so it rolls up with the generation
        // span rather than being emitted detached from the trace it belongs to.
        const ended = workoutImportStreamTerminalOutcome(clientLeft());
        await recordTerminalOutcome(ended.outcome, ended.reason);
        } catch (error) {
          const ended = workoutImportStreamTerminalOutcome(clientLeft(), workoutImportFailureCode(error));
          await recordTerminalOutcome(ended.outcome, ended.reason);
          throw error;
        }
      });
      if (!writable()) {
        logger.info("workout_import_stream.abandoned", {
          uid,
          deltas: deltaCount,
          inputTokens: usage.usage.input_tokens,
          outputTokens: usage.usage.output_tokens,
          latencyMs: Date.now() - started,
        });
        return;
      }
      res.write(serverSentEvent({ type: "done", model: IMPORT_STREAM_MODEL }));
      logger.info("workout_import_stream.ok", {
        uid,
        model: IMPORT_STREAM_MODEL,
        images: payload.images.length,
        deltas: deltaCount,
        characters,
        inputTokens: usage.usage.input_tokens,
        outputTokens: usage.usage.output_tokens,
        latencyMs: Date.now() - started,
      });
    } catch (error) {
      const reasonCode = workoutImportFailureCode(error);
      if (clientLeft()) {
        logger.info("workout_import_stream.abandoned", {
          uid,
          deltas: deltaCount,
          inputTokens: usage.usage.input_tokens,
          outputTokens: usage.usage.output_tokens,
          latencyMs: Date.now() - started,
        });
        return;
      }
      logger.error("workout_import_stream.provider_error", {
        uid,
        model: IMPORT_STREAM_MODEL,
        deltas: deltaCount,
        inputTokens: usage.usage.input_tokens,
        outputTokens: usage.usage.output_tokens,
        latencyMs: Date.now() - started,
        reasonCode,
      });
      // Whatever already streamed stays valid; the client keeps the exercises it received and
      // decides whether the skeleton is worth showing.
      if (writable()) res.write(serverSentEvent({ type: "error", code: reasonCode }));
    } finally {
      await flushLLMObservability();
      res.end();
    }
  },
);

/** The bearer token's uid, or null when it is missing, malformed, or not ours. */
async function verifiedUID(authorization: string | undefined): Promise<string | null> {
  const token = authorization?.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  if (!token) return null;
  try {
    return (await getAuth().verifyIdToken(token)).uid;
  } catch {
    return null;
  }
}

/** App Check is verified here by hand because `onRequest` has no `enforceAppCheck`. */
async function appCheckAccepted(token: string | undefined): Promise<boolean> {
  if (!ENFORCE_IMPORT_APP_CHECK) return true;
  if (!token) return false;
  try {
    await getAppCheck().verifyToken(token);
    return true;
  } catch {
    return false;
  }
}

export const startWorkoutImportJob = onCall(
  {
    secrets: [langfuseSecretKey, langfusePublicKey, langfuseBaseURL],
    region: "us-central1",
    cors: true,
    enforceAppCheck: ENFORCE_IMPORT_APP_CHECK,
    timeoutSeconds: 45,
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    let payload: ReturnType<typeof parseStartWorkoutImportJobPayload>;
    try {
      payload = parseStartWorkoutImportJobPayload(
        (req.data as { payload?: unknown } | undefined)?.payload,
      );
      configureObservabilityFromSecrets();
      return await withLLMTrace("server.job_accept", {
        traceID: payload.clientJobID,
        sessionID: payload.clientJobID,
        surface: "import.image.durable",
        uid: req.auth.uid,
        model: IMPORT_MODEL,
        promptVersion: LLM_OBSERVABILITY_VERSIONS.importPrompt,
        outputSchemaVersion: LLM_OBSERVABILITY_VERSIONS.importOutput,
        validatorVersion: LLM_OBSERVABILITY_VERSIONS.importValidator,
        ...payload.observability,
      }, () => workoutImportRuntime().start(req.auth!.uid, payload, IMPORT_MODEL));
    } catch (error) {
      throw workoutImportCallableError(error);
    } finally {
      await flushLLMObservability();
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
  {
    secrets: [langfuseSecretKey, langfusePublicKey, langfuseBaseURL],
    region: "us-central1",
    cors: true,
    enforceAppCheck: ENFORCE_IMPORT_APP_CHECK,
    timeoutSeconds: 45,
  },
  async (req) => {
    if (!req.auth) throw new HttpsError("unauthenticated", "Please sign in.");
    try {
      configureObservabilityFromSecrets();
      const command = parseJobCommand((req.data as { payload?: unknown } | undefined)?.payload, true);
      if (!command.requestID) throw new HttpsError("invalid-argument", "Invalid request.");
      return await workoutImportRuntime().cancel(req.auth.uid, {
        serverJobID: command.serverJobID,
        requestID: command.requestID,
      });
    } catch (error) {
      throw workoutImportCallableError(error);
    } finally {
      await flushLLMObservability();
    }
  },
);

export const processWorkoutImportJob = onTaskDispatched<{
  serverJobID: string;
  generation: number;
  dispatchAttempt: number;
}>(
  {
    secrets: providerAndObservabilitySecrets,
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
    configureObservabilityFromSecrets();
    const client = createWorkoutImportProviderClient(
      (await import("@anthropic-ai/sdk")).default,
      anthropicKey.value(),
    );
    try {
      await workoutImportRuntime({
        request: async (content, maxTokens, context) => {
          const request = buildWorkoutImportProviderRequest(IMPORT_MODEL, content, maxTokens);
          const message = await withLLMGeneration({
            name: context?.callKind === "repair"
              ? `llm.generation.repair.${context.repairIndex}`
              : "llm.generation.initial",
            model: IMPORT_MODEL,
            maxTokens: request.max_tokens,
            temperature: request.temperature,
            toolChoice: "submit_workout_import_ir",
            requestContent: content,
            messageCount: request.messages.length,
            toolSchemaBytes: Buffer.byteLength(JSON.stringify(request.tools), "utf8"),
            toolSchemaTokens: importToolSchemaTokens("durable"),
            callIndex: context?.callIndex,
            sectionIndex: context?.sectionIndex,
            repairIndex: context?.repairIndex,
            providerRetryIndex: context?.providerRetryIndex,
          }, () => client.messages.create(request));
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
    } finally {
      await flushLLMObservability();
    }
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

function configureObservabilityFromSecrets(): boolean {
  try {
    return configureLLMObservability({
      secretKey: langfuseSecretKey.value(),
      publicKey: langfusePublicKey.value(),
      baseURL: langfuseBaseURL.value(),
    });
  } catch {
    return false;
  }
}

function conversationTraceContext(
  data: Record<string, unknown>,
  uid: string,
  model: string,
): {
  traceID: string;
  sessionID: string;
  surface: LLMSurface;
  uid: string;
  model: string;
  promptVersion: string;
  toolSchemaVersion: string;
  outputSchemaVersion: string;
  validatorVersion: string;
  roundIndex: number;
} & AppTraceMetadata {
  const traceID = validTraceID(data.traceID) ?? randomUUID();
  const sessionID = safeString(data.sessionID, 120) ?? traceID;
  const surface = allowedChatSurface(data.surface);
  const servedToolset = servedToolsetForClientSchema(data.clientToolSchemaVersion);
  return {
    traceID,
    sessionID,
    surface,
    uid,
    model,
    promptVersion: conversationPromptVersion(servedToolset),
    toolSchemaVersion: conversationToolSchemaVersion(servedToolset),
    outputSchemaVersion: LLM_OBSERVABILITY_VERSIONS.conversationOutput,
    validatorVersion: LLM_OBSERVABILITY_VERSIONS.conversationValidator,
    roundIndex: boundedInteger(data.roundIndex, 0, 12),
    appVersion: safeString(data.appVersion, 40),
    appBuild: safeString(data.appBuild, 40),
    iosVersion: safeString(data.iosVersion, 80),
    deviceClass: safeString(data.deviceClass, 40),
  };
}

function parseToolEvents(raw: unknown) {
  let value = raw;
  if (typeof value === "string") {
    try { value = JSON.parse(value); } catch { return []; }
  }
  return parseClientToolObservations(value);
}

function allowedChatSurface(value: unknown): LLMSurface {
  switch (value) {
  case "chat.today":
  case "chat.plan":
  case "chat.workout":
  case "chat.import_fix":
    return value;
  default:
    return "chat.today";
  }
}

function allowedChatTerminalOutcome(value: unknown): string | undefined {
  switch (value) {
  case "tool_round_exhausted":
  case "client_failed":
  case "provider_failed":
  case "cancelled":
    return value;
  default:
    return undefined;
  }
}

function validTraceID(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const compact = value.toLowerCase().replaceAll("-", "");
  return /^[0-9a-f]{32}$/.test(compact) && compact !== "00000000000000000000000000000000"
    ? compact
    : undefined;
}

function safeString(value: unknown, maximumLength: number): string | undefined {
  return typeof value === "string" && value.length > 0 ? value.slice(0, maximumLength) : undefined;
}

function boundedInteger(value: unknown, minimum: number, maximum: number): number {
  const parsed = typeof value === "string" && /^\d{1,3}$/.test(value) ? Number(value) : value;
  const number = typeof parsed === "number" ? Math.trunc(parsed) : minimum;
  return Math.max(minimum, Math.min(number, maximum));
}

function durableImportObservability(): WorkoutImportObservability {
  return {
    withTrace: async (job, operation) => withLLMTrace("server.worker", importTraceContext(job), operation),
    withSection: async (_job, section, operation) => withLLMSpan(`section.${section.order}`, {
      section_index: section.order,
      generation: section.generation,
      input_bytes: section.observations.reduce((sum, observation) => sum + observation.text.length, 0),
      observed_count: section.observations.length,
      repair_count: section.repairAttempts,
    }, operation),
    validator: async (section, diagnostic, repairIndex, durationMilliseconds, willRepair) => {
      await recordValidatorObservation({
        validatorName: "workout-import-ir",
        validatorVersion: LLM_OBSERVABILITY_VERSIONS.importValidator,
        attemptKind: repairIndex === 0 ? "initial" : "repair",
        passed: diagnostic === undefined,
        durationMilliseconds,
        ruleCode: diagnostic?.code,
        stage: diagnostic?.boundary,
        path: diagnostic?.path,
        relationshipRule: diagnostic?.relationshipRule,
        observedCount: diagnostic?.observedCount,
        expectedCount: diagnostic?.expectedExerciseCount,
        rejectedRecordKind: diagnostic?.recordKind,
        repairCount: repairIndex,
        repairRequested: willRepair,
        finalAction: diagnostic === undefined ? "accept" : willRepair ? "repair" : "fallback",
        relatedIdentifiers: diagnostic?.relatedObservationIDs,
      });
      logger.debug("workout_import_job.validation_observed", {
        sectionOrder: section.order,
        repairIndex,
        passed: diagnostic === undefined,
      });
    },
    terminal: async (outcome, fallbackReason, metadata) => {
      await recordTerminalOutcome(outcome, fallbackReason, metadata);
    },
  };
}

function importTraceContext(job: StoredWorkoutImportJob) {
  const createdAt = timestampMilliseconds(job.createdAt);
  return {
    traceID: job.clientJobID,
    sessionID: job.clientJobID,
    surface: "import.image.durable" as const,
    uid: job.uid,
    model: job.model,
    promptVersion: LLM_OBSERVABILITY_VERSIONS.importPrompt,
    outputSchemaVersion: LLM_OBSERVABILITY_VERSIONS.importOutput,
    validatorVersion: LLM_OBSERVABILITY_VERSIONS.importValidator,
    generation: job.generation,
    dispatchAttempt: job.dispatchAttempt,
    queueMilliseconds: createdAt === undefined ? undefined : Math.max(0, Date.now() - createdAt),
    ...job.observability,
  };
}

function timestampMilliseconds(value: unknown): number | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const toMillis = (value as { toMillis?: unknown }).toMillis;
  if (typeof toMillis !== "function") return undefined;
  const milliseconds = (toMillis as () => unknown).call(value);
  return typeof milliseconds === "number" && Number.isFinite(milliseconds) ? milliseconds : undefined;
}

function catalogFingerprint(catalogHints: string[]): string {
  return `sha256:${createHash("sha256").update([...catalogHints].sort().join("\n")).digest("hex")}`;
}

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
    observability: durableImportObservability(),
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
