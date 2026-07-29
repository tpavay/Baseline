import { createHash, createHmac, randomBytes } from "node:crypto";

import { LangfuseSpanProcessor } from "@langfuse/otel";
import {
  LangfuseGeneration,
  propagateAttributes,
  startActiveObservation,
} from "@langfuse/tracing";
import { NodeSDK } from "@opentelemetry/sdk-node";
import * as logger from "firebase-functions/logger";

export const LLM_OBSERVABILITY_VERSIONS = {
  samplingPolicy: "all-v1",
  pricing: "langfuse-model-pricing-live-v1",
  conversationPrompt: "conversation-prompt-v6",
  conversationTools: "conversation-tools-v8",
  conversationOutput: "anthropic-content-blocks-v1",
  conversationValidator: "tool-mapper-v1",
  importPrompt: "workout-import-prompt-v1",
  importOutput: "workout-import-ir-v1",
  importValidator: "workout-import-validator-v1",
} as const;

/**
 * The conversation callable serves Wave 9, Wave 8, Wave 7, Wave 6, Wave 5, and legacy toolsets, so
 * the trace records which one the model actually saw rather than one constant.
 */
export function conversationToolSchemaVersion(servedToolset: string): string {
  return `${LLM_OBSERVABILITY_VERSIONS.conversationTools}-${servedToolset}`;
}

/**
 * The system prompt's editing guidance is likewise toolset-matched (see prompt.ts), so the trace
 * records the prompt variant the model actually saw alongside the served tool schema.
 */
export function conversationPromptVersion(servedToolset: string): string {
  return `${LLM_OBSERVABILITY_VERSIONS.conversationPrompt}-${servedToolset}`;
}

export type LLMSurface =
  | "chat.today"
  | "chat.plan"
  | "chat.workout"
  | "chat.import_fix"
  | "import.image.durable"
  | "import.image.legacy"
  | "import.image.stream";

export interface AppTraceMetadata {
  appVersion?: string;
  appBuild?: string;
  iosVersion?: string;
  deviceClass?: string;
}

export interface LLMTraceContext extends AppTraceMetadata {
  traceID: string;
  sessionID: string;
  surface: LLMSurface;
  uid?: string;
  model: string;
  promptVersion: string;
  toolSchemaVersion?: string;
  outputSchemaVersion: string;
  validatorVersion: string;
  catalogVersion?: string;
  roundIndex?: number;
  generation?: number;
  dispatchAttempt?: number;
  queueMilliseconds?: number;
}

export interface GenerationContext {
  name: string;
  model: string;
  maxTokens: number;
  temperature?: number;
  toolChoice?: string;
  requestContent?: string;
  messageCount?: number;
  toolSchemaBytes?: number;
  /**
   * The fixture-measured token cost of the served tool schemas (toolSchemaTokens.ts). Bytes are
   * not tokens, so this is what lets a generation's input tokens decompose into schema / prompt /
   * conversation in a Langfuse query.
   */
  toolSchemaTokens?: number;
  callIndex?: number;
  roundIndex?: number;
  sectionIndex?: number;
  repairIndex?: number;
  providerRetryIndex?: number;
  /**
   * Whether this request streams. A streaming operation still has to return an Anthropic-shaped
   * object carrying the accumulated `usage`, because that is what the cost derivation reads.
   */
  streaming?: boolean;
  /**
   * The usage accumulated so far, for an operation that may fail part way through.
   *
   * Cost is normally derived from what the operation returns, which a throwing operation never
   * does - so a stream that dies mid-response, or one the athlete walked away from, would report
   * zero tokens for work the provider has already billed. That is the expensive case this exists
   * to measure, so when this is supplied the error path attaches it too.
   */
  partialUsage?: () => unknown;
}

export interface ValidatorObservation {
  validatorName: string;
  validatorVersion: string;
  attemptKind: "initial" | "repair" | "decode" | "scope";
  passed: boolean;
  durationMilliseconds: number;
  ruleCode?: string;
  stage?: string;
  path?: string;
  relationshipRule?: string;
  observedCount?: number;
  expectedCount?: number;
  rejectedRecordKind?: string;
  rejectedOutputBytes?: number;
  repairCount?: number;
  repairRequested?: boolean;
  finalAction: "accept" | "repair" | "fallback" | "terminal_reject" | "execute" | "reject";
  relatedIdentifiers?: string[];
}

export interface ClientToolObservation {
  toolUseID: string;
  name: string;
  roundIndex: number;
  requestedOrder: number;
  argumentSummary: unknown;
  argumentHash: string;
  decodeResult: "passed" | "failed";
  permissionResult: "passed" | "failed" | "not_evaluated";
  resultCategory: string;
  resultSummary: unknown;
  resultHash: string;
  errorCode?: string;
  decodeMilliseconds: number;
  permissionMilliseconds: number;
  executionMilliseconds: number;
  durationMilliseconds: number;
  readOnly: boolean;
}

interface ConfigureOptions {
  publicKey?: string;
  secretKey?: string;
  baseURL?: string;
}

let spanProcessor: LangfuseSpanProcessor | undefined;
let sdk: NodeSDK | undefined;
let contentHashKey: string | undefined;
let initializationAttempted = false;

const CLIENT_TOOL_RESULT_CATEGORIES = new Set([
  "completed", "applied", "not_found", "ambiguous", "confirmation_required",
  "health_permission_denied", "malformed", "rejected_scope", "error",
]);
const CLIENT_TOOL_ERROR_CODES = new Set([
  "invalid_tool_call", "scope_denied", "tool_execution_failed",
]);

const SAFE_METADATA_KEYS = new Set([
  "surface", "model", "provider", "temperature", "streaming", "retryable", "truncated",
  "generation", "passed", "requested", "stage", "path",
  "string", "number", "boolean", "array", "object", "null", "other",
  "app_version", "app_build", "ios_version", "device_class", "trace_id", "session_id",
  "correlation_id", "function_revision", "provider_sdk_version", "prompt_version",
  "tool_schema_version", "output_schema_version", "validator_version", "catalog_version",
  "content_capture", "sampling_policy_version", "pricing_version", "round_index", "call_index",
  "section_index", "repair_index", "provider_retry_index", "dispatch_attempt", "queue_ms",
  "prompt_bytes", "response_bytes", "message_count", "tool_schema_bytes", "tool_schema_tokens",
  "request_id",
  "stop_reason", "error_type", "http_status", "provider_error_code", "provider_error_message",
  "tool_use_id", "requested_order",
  "argument_hash", "decode_result", "permission_result", "result_category", "result_hash",
  "error_code", "decode_ms", "permission_ms", "execution_ms", "duration_ms", "read_only",
  "validator_name", "attempt_kind", "rule_code", "relationship_rule", "observed_count",
  "expected_count", "rejected_record_kind", "rejected_output_bytes", "repair_count",
  "repair_requested", "final_action", "related_id_hash", "related_id_count", "terminal_outcome",
  "fallback_reason", "tool_count", "text_block_count", "input_hash", "output_hash",
  "input_bytes", "output_bytes", "argument_count", "value_type_counts", "text_bytes",
  "has_decision", "has_plan", "tool_choice", "max_tokens",
  "section_count", "completed_section_count",
  "total", "cache_read_input_tokens", "cache_creation_input_tokens",
  "input_cost", "output_cost", "total_cost",
]);

/** Initializes one exporter per warm Cloud Functions instance. Missing config is a supported no-op. */
export function configureLLMObservability(options: ConfigureOptions): boolean {
  if (spanProcessor) return true;
  const publicKey = options.publicKey?.trim();
  const secretKey = options.secretKey?.trim();
  const baseURL = options.baseURL?.trim();
  if (!publicKey || !secretKey || !baseURL) return false;
  if (initializationAttempted) return false;
  initializationAttempted = true;

  try {
    contentHashKey = secretKey;
    spanProcessor = new LangfuseSpanProcessor({
      publicKey,
      secretKey,
      baseUrl: baseURL,
      environment: deploymentEnvironment(),
      release: functionRevision(),
      exportMode: "immediate",
      mediaUploadEnabled: false,
      timeout: 2,
      mask: ({ data }) => maskLangfuseData(data),
    });
    sdk = new NodeSDK({ spanProcessors: [spanProcessor] });
    sdk.start();
    return true;
  } catch (error) {
    spanProcessor = undefined;
    sdk = undefined;
    contentHashKey = undefined;
    logger.warn("llm_observability_initialization_failed", {
      errorType: errorName(error),
    });
    return false;
  }
}

const FLUSH_DEADLINE_MILLISECONDS = 300;

/**
 * Serverless runtimes may freeze after returning, so every traced handler kicks off an export. The
 * export runs fire-and-forget with all failures swallowed, and the handler waits at most a short
 * deadline so an unreachable exporter can never add meaningful latency to the user-facing response.
 */
export async function flushLLMObservability(): Promise<void> {
  if (!spanProcessor) return;
  const flush = spanProcessor
    .forceFlush()
    .catch((error) => logger.warn("llm_observability_export_failed", { errorType: errorName(error) }));
  await Promise.race([flush, flushDeadline(FLUSH_DEADLINE_MILLISECONDS)]);
}

function flushDeadline(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    if (typeof timer.unref === "function") timer.unref();
  });
}

/** Config-driven sampling knob. Defaults to full tracing; deterministic per trace identifier. */
export function shouldSampleTelemetry(identifier: string): boolean {
  const rate = telemetrySampleRate();
  if (rate >= 1) return true;
  if (rate <= 0) return false;
  const bucket = parseInt(createHash("sha256").update(identifier).digest("hex").slice(0, 8), 16);
  return bucket / 0xffffffff < rate;
}

function telemetrySampleRate(): number {
  const raw = process.env.LLM_OBSERVABILITY_SAMPLE_RATE;
  if (raw === undefined || raw.trim() === "") return 1;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? Math.max(0, Math.min(parsed, 1)) : 1;
}

export async function withLLMTrace<T>(
  name: string,
  context: LLMTraceContext,
  operation: () => Promise<T>,
): Promise<T> {
  if (!spanProcessor) return operation();
  const traceID = normalizeTraceID(context.traceID);
  const metadata = traceMetadata(context);
  let operationCompleted = false;
  let operationFailed = false;
  let operationResult: T | undefined;
  let operationError: unknown;
  try {
    return await startActiveObservation(name, async (span) => {
      span.update({
        input: { content_capture: "none", surface: context.surface },
        metadata,
        version: context.promptVersion,
      });
      return propagateAttributes({
        userId: context.uid ? pseudonymousUserID(context.uid) : undefined,
        sessionId: bounded(context.sessionID),
        tags: [context.surface, "metadata-only"],
        version: context.promptVersion,
        traceName: context.surface.startsWith("chat.") ? "chat.turn" : context.surface,
        metadata: propagationMetadata(metadata),
      }, async () => {
        try {
          const result = await operation();
          operationResult = result;
          operationCompleted = true;
          return result;
        } catch (error) {
          operationFailed = true;
          operationError = error;
          try {
            span.update({
              level: "ERROR",
              statusMessage: errorName(error),
              output: { terminal_outcome: "provider_failed" },
            });
          } catch {
            logInstrumentationFailure("trace_error_update");
          }
          throw error;
        }
      });
    }, {
      parentSpanContext: {
        traceId: traceID,
        spanId: randomSpanID(),
        traceFlags: 1,
        isRemote: true,
      },
    });
  } catch (error) {
    if (operationFailed) throw operationError;
    logInstrumentationFailure("trace_wrapper", error);
    if (operationCompleted) return operationResult as T;
    return operation();
  }
}

export async function withLLMSpan<T>(
  name: string,
  metadata: Record<string, unknown>,
  operation: () => Promise<T>,
): Promise<T> {
  if (!spanProcessor) return operation();
  let operationCompleted = false;
  let operationFailed = false;
  let operationResult: T | undefined;
  let operationError: unknown;
  try {
    return await startActiveObservation(name, async (span) => {
      span.update({ metadata: safeMetadata(metadata) });
      try {
        const result = await operation();
        operationResult = result;
        operationCompleted = true;
        return result;
      } catch (error) {
        operationFailed = true;
        operationError = error;
        throw error;
      }
    });
  } catch (error) {
    if (operationFailed) throw operationError;
    logInstrumentationFailure("span_wrapper", error);
    if (operationCompleted) return operationResult as T;
    return operation();
  }
}

/** Recommended Langfuse context-manager wrapper for one provider request. */
export async function withLLMGeneration<T>(
  context: GenerationContext,
  operation: () => Promise<T>,
): Promise<T> {
  if (!spanProcessor) return operation();
  const requestBytes = context.requestContent === undefined
    ? undefined
    : Buffer.byteLength(context.requestContent, "utf8");
  let operationCompleted = false;
  let operationFailed = false;
  let operationResult: T | undefined;
  let operationError: unknown;
  try {
    return await startActiveObservation(context.name, async (generation) => {
      generation.update({
        model: context.model,
        modelParameters: {
          maxTokens: context.maxTokens,
          streaming: context.streaming === true ? "true" : "false",
          ...(context.temperature === undefined ? {} : { temperature: context.temperature }),
          ...(context.toolChoice === undefined ? {} : { toolChoice: context.toolChoice }),
        },
        input: {
          content_capture: "none",
          input_bytes: requestBytes,
          input_hash: context.requestContent === undefined ? undefined : privateHash(context.requestContent),
          message_count: context.messageCount,
          tool_schema_bytes: context.toolSchemaBytes,
          tool_schema_tokens: context.toolSchemaTokens,
        },
        metadata: safeMetadata({
          call_index: context.callIndex,
          round_index: context.roundIndex,
          section_index: context.sectionIndex,
          repair_index: context.repairIndex,
          provider_retry_index: context.providerRetryIndex,
          streaming: context.streaming === true,
          temperature: context.temperature,
          tool_choice: context.toolChoice,
          prompt_bytes: requestBytes,
          message_count: context.messageCount,
          tool_schema_bytes: context.toolSchemaBytes,
          tool_schema_tokens: context.toolSchemaTokens,
          pricing_version: LLM_OBSERVABILITY_VERSIONS.pricing,
        }),
      });
      const started = Date.now();
      try {
        const response = await operation();
        operationResult = response;
        operationCompleted = true;
        try {
          updateGenerationFromAnthropic(generation, response, Date.now() - started);
          await recordModelToolRequests(response, context.roundIndex);
        } catch (error) {
          logInstrumentationFailure("generation_result_update", error);
        }
        return response;
      } catch (error) {
        operationFailed = true;
        operationError = error;
        try {
          const partial = anthropicUsageDetails(context.partialUsage?.());
          const providerError = providerErrorDetail(error);
          generation.update({
            level: "ERROR",
            statusMessage: errorName(error),
            ...(partial === undefined ? {} : { usageDetails: partial }),
            metadata: safeMetadata({
              error_type: errorName(error),
              http_status: errorStatus(error),
              provider_error_code: providerError.code,
              provider_error_message: providerError.message,
              retryable: isRetryableProviderError(error),
              duration_ms: Date.now() - started,
            }),
          });
        } catch {
          logInstrumentationFailure("generation_error_update");
        }
        throw error;
      }
    }, { asType: "generation" });
  } catch (error) {
    if (operationFailed) throw operationError;
    logInstrumentationFailure("generation_wrapper", error);
    if (operationCompleted) return operationResult as T;
    return operation();
  }
}

export async function recordValidatorObservation(value: ValidatorObservation): Promise<void> {
  if (!spanProcessor) return;
  try {
    await startActiveObservation(validatorObservationName(value), async (observation) => {
      const related = value.relatedIdentifiers ?? [];
      observation.update({
        input: { validator_name: value.validatorName, attempt_kind: value.attemptKind },
        output: { passed: value.passed, final_action: value.finalAction },
        level: value.passed ? "DEFAULT" : "WARNING",
        metadata: safeMetadata({
          validator_name: value.validatorName,
          validator_version: value.validatorVersion,
          attempt_kind: value.attemptKind,
          passed: value.passed,
          duration_ms: value.durationMilliseconds,
          rule_code: value.ruleCode,
          stage: value.stage,
          path: value.path,
          relationship_rule: value.relationshipRule,
          observed_count: value.observedCount,
          expected_count: value.expectedCount,
          rejected_record_kind: value.rejectedRecordKind,
          rejected_output_bytes: value.rejectedOutputBytes,
          repair_count: value.repairCount,
          repair_requested: value.repairRequested,
          final_action: value.finalAction,
          related_id_hash: related.length > 0 ? privateHash(related.slice().sort().join("|")) : undefined,
          related_id_count: related.length,
        }),
        version: value.validatorVersion,
      });
    }, { asType: "evaluator" });
  } catch (error) {
    logInstrumentationFailure("validator_observation", error);
  }
}

export async function recordTerminalOutcome(
  terminalOutcome: string,
  fallbackReason?: string,
  metadata: Record<string, unknown> = {},
): Promise<void> {
  if (!spanProcessor) return;
  try {
    await propagateAttributes({
      metadata: {
        terminal_outcome: terminalOutcome,
        fallback_reason: fallbackReason ?? "none",
      },
    }, () => startActiveObservation("terminal.outcome", async (span) => {
      span.update({
        output: { terminal_outcome: terminalOutcome, fallback_reason: fallbackReason ?? null },
        level: terminalOutcome.includes("failed") ? "ERROR" :
          terminalOutcome.includes("fallback") ? "WARNING" : "DEFAULT",
        metadata: safeMetadata({
          terminal_outcome: terminalOutcome,
          fallback_reason: fallbackReason,
          ...metadata,
        }),
      });
    }));
  } catch (error) {
    logInstrumentationFailure("terminal_observation", error);
  }
}

export async function recordClientToolObservations(events: ClientToolObservation[]): Promise<void> {
  if (!spanProcessor) return;
  for (const event of events.slice(0, 24)) {
    if (!/^[a-z0-9_]{1,80}$/.test(event.name)) continue;
    try {
      await startActiveObservation(`client.tool.${event.name}`, async (tool) => {
        tool.update({
          input: event.argumentSummary,
          output: event.resultSummary,
          level: event.errorCode ? "WARNING" : "DEFAULT",
          metadata: safeMetadata({
            tool_use_id: bounded(event.toolUseID),
            round_index: event.roundIndex,
            requested_order: event.requestedOrder,
            argument_hash: privateHash(`client-argument-v1:${event.argumentHash}`),
            decode_result: event.decodeResult,
            permission_result: event.permissionResult,
            result_category: bounded(event.resultCategory),
            result_hash: privateHash(`client-result-v1:${event.resultHash}`),
            error_code: event.errorCode,
            decode_ms: event.decodeMilliseconds,
            permission_ms: event.permissionMilliseconds,
            execution_ms: event.executionMilliseconds,
            duration_ms: event.durationMilliseconds,
            read_only: event.readOnly,
          }),
        });
        await recordValidatorObservation({
          validatorName: "tool-decode",
          validatorVersion: LLM_OBSERVABILITY_VERSIONS.conversationValidator,
          attemptKind: "decode",
          passed: event.decodeResult === "passed",
          durationMilliseconds: event.decodeMilliseconds,
          ruleCode: event.decodeResult === "passed" ? "decoded" : "malformed",
          finalAction: event.decodeResult === "passed" ? "execute" : "reject",
        });
        await recordValidatorObservation({
          validatorName: "scope-permission",
          validatorVersion: LLM_OBSERVABILITY_VERSIONS.conversationValidator,
          attemptKind: "scope",
          passed: event.permissionResult !== "failed",
          durationMilliseconds: event.permissionMilliseconds,
          ruleCode: event.permissionResult,
          finalAction: event.permissionResult === "failed" ? "reject" : "execute",
        });
      }, { asType: "tool" });
    } catch (error) {
      logInstrumentationFailure("tool_observation", error);
    }
  }
}

export function parseClientToolObservations(raw: unknown): ClientToolObservation[] {
  if (!Array.isArray(raw)) return [];
  const observations: ClientToolObservation[] = [];
  for (const candidate of raw.slice(0, 24)) {
    if (!isRecord(candidate) || typeof candidate.toolUseID !== "string" ||
        typeof candidate.name !== "string" || !/^[a-z0-9_]{1,80}$/.test(candidate.name) ||
        !Number.isInteger(candidate.roundIndex) || !Number.isInteger(candidate.requestedOrder) ||
        typeof candidate.argumentHash !== "string" || !/^[0-9a-f]{64}$/i.test(candidate.argumentHash) ||
        typeof candidate.resultHash !== "string" || !/^[0-9a-f]{64}$/i.test(candidate.resultHash) ||
        typeof candidate.decodeMilliseconds !== "number" ||
        !Number.isFinite(candidate.decodeMilliseconds) ||
        typeof candidate.permissionMilliseconds !== "number" ||
        !Number.isFinite(candidate.permissionMilliseconds) ||
        typeof candidate.executionMilliseconds !== "number" ||
        !Number.isFinite(candidate.executionMilliseconds) ||
        typeof candidate.durationMilliseconds !== "number" ||
        !Number.isFinite(candidate.durationMilliseconds) ||
        typeof candidate.readOnly !== "boolean") continue;
    const decodeResult = candidate.decodeResult === "passed" ? "passed" :
      candidate.decodeResult === "failed" ? "failed" : undefined;
    const permissionResult = candidate.permissionResult === "passed" ? "passed" :
      candidate.permissionResult === "failed" ? "failed" :
        candidate.permissionResult === "not_evaluated" ? "not_evaluated" : undefined;
    if (!decodeResult || !permissionResult || typeof candidate.resultCategory !== "string" ||
        !CLIENT_TOOL_RESULT_CATEGORIES.has(candidate.resultCategory)) continue;
    const errorCode = typeof candidate.errorCode === "string" &&
      CLIENT_TOOL_ERROR_CODES.has(candidate.errorCode) ? candidate.errorCode : undefined;
    observations.push({
      toolUseID: candidate.toolUseID.slice(0, 120),
      name: candidate.name,
      roundIndex: boundedInteger(candidate.roundIndex, 0, 12),
      requestedOrder: boundedInteger(candidate.requestedOrder, 0, 100),
      argumentSummary: sanitizeArgumentSummary(candidate.argumentSummary),
      argumentHash: candidate.argumentHash.slice(0, 128),
      decodeResult,
      permissionResult,
      resultCategory: candidate.resultCategory.slice(0, 80),
      resultSummary: sanitizeResultSummary(candidate.resultSummary),
      resultHash: candidate.resultHash.slice(0, 128),
      ...(errorCode ? { errorCode } : {}),
      decodeMilliseconds: boundedMilliseconds(candidate.decodeMilliseconds),
      permissionMilliseconds: boundedMilliseconds(candidate.permissionMilliseconds),
      executionMilliseconds: boundedMilliseconds(candidate.executionMilliseconds),
      durationMilliseconds: Math.max(0, Math.min(candidate.durationMilliseconds, 600_000)),
      readOnly: candidate.readOnly,
    });
  }
  return observations;
}

export function normalizeTraceID(value: string): string {
  const compact = value.toLowerCase().replaceAll("-", "");
  if (/^[0-9a-f]{32}$/.test(compact) && compact !== "00000000000000000000000000000000") {
    return compact;
  }
  return createHash("sha256").update(value).digest("hex").slice(0, 32);
}

/** Defense-in-depth exporter masker. Application code should only submit structural data. */
export function maskLangfuseData(data: unknown): unknown {
  if (typeof data !== "string") return sanitizeExportValue(data);
  try {
    return JSON.stringify(sanitizeExportValue(JSON.parse(data)));
  } catch {
    return safeCode(data) ? data : "[REDACTED]";
  }
}

function traceMetadata(context: LLMTraceContext): Record<string, unknown> {
  return safeMetadata({
    surface: context.surface,
    trace_id: normalizeTraceID(context.traceID),
    session_id: bounded(context.sessionID),
    correlation_id: bounded(context.traceID),
    app_version: context.appVersion,
    app_build: context.appBuild,
    ios_version: context.iosVersion,
    device_class: context.deviceClass,
    function_revision: functionRevision(),
    model: context.model,
    provider: "anthropic",
    provider_sdk_version: "0.30.1",
    prompt_version: context.promptVersion,
    tool_schema_version: context.toolSchemaVersion,
    output_schema_version: context.outputSchemaVersion,
    validator_version: context.validatorVersion,
    catalog_version: context.catalogVersion,
    content_capture: "none",
    sampling_policy_version: LLM_OBSERVABILITY_VERSIONS.samplingPolicy,
    pricing_version: LLM_OBSERVABILITY_VERSIONS.pricing,
    round_index: context.roundIndex,
    generation: context.generation,
    dispatch_attempt: context.dispatchAttempt,
    queue_ms: context.queueMilliseconds,
  });
}

/**
 * The token counts Langfuse prices from, or undefined when the value carries none. Shared by the
 * success and failure branches so a partial stream is costed exactly like a complete one.
 */
export function anthropicUsageDetails(response: unknown): Record<string, number> | undefined {
  const candidate = isRecord(response) ? response : {};
  const usage = isRecord(candidate.usage) ? candidate.usage : {};
  const input = nonnegativeNumber(usage.input_tokens);
  const output = nonnegativeNumber(usage.output_tokens);
  const cacheRead = nonnegativeNumber(usage.cache_read_input_tokens);
  const cacheCreation = nonnegativeNumber(usage.cache_creation_input_tokens);
  const usageDetails: Record<string, number> = {};
  if (input !== undefined) usageDetails.input = input;
  if (output !== undefined) usageDetails.output = output;
  if (cacheRead !== undefined) usageDetails.cache_read_input_tokens = cacheRead;
  if (cacheCreation !== undefined) usageDetails.cache_creation_input_tokens = cacheCreation;
  if (Object.keys(usageDetails).length === 0) return undefined;
  usageDetails.total = Object.values(usageDetails).reduce((sum, value) => sum + value, 0);
  return usageDetails;
}

function updateGenerationFromAnthropic(
  generation: LangfuseGeneration,
  response: unknown,
  durationMilliseconds: number,
): void {
  const candidate = isRecord(response) ? response : {};
  const usageDetails = anthropicUsageDetails(response);
  // Langfuse derives USD cost from the exact model and usage details using its managed price table.
  // pricing_version on the observation makes that derived cost policy explicit and queryable.
  const encoded = safeJSONString(response);
  const summary = summarizeAnthropicResponse(candidate);
  generation.update({
    output: summary,
    ...(usageDetails === undefined ? {} : { usageDetails }),
    metadata: safeMetadata({
      duration_ms: durationMilliseconds,
      response_bytes: Buffer.byteLength(encoded, "utf8"),
      output_hash: privateHash(encoded),
      request_id: typeof candidate._request_id === "string" ? candidate._request_id : undefined,
      stop_reason: typeof candidate.stop_reason === "string" ? candidate.stop_reason : undefined,
      truncated: candidate.stop_reason === "max_tokens",
    }),
  });
}

async function recordModelToolRequests(response: unknown, roundIndex?: number): Promise<void> {
  if (!isRecord(response) || !Array.isArray(response.content)) return;
  let requestedOrder = 0;
  for (const block of response.content) {
    if (!isRecord(block) || block.type !== "tool_use" || typeof block.name !== "string" ||
        !/^[a-z0-9_]{1,80}$/.test(block.name)) continue;
    const input = isRecord(block.input) ? block.input : {};
    await startActiveObservation(`model.tool_request.${block.name}`, async (tool) => {
      tool.update({
        input: summarizeArguments(input),
        output: { requested: true },
        metadata: safeMetadata({
          tool_use_id: typeof block.id === "string" ? bounded(block.id) : undefined,
          round_index: roundIndex,
          requested_order: requestedOrder,
          argument_hash: privateHash(stableJSONString(input)),
        }),
      });
    }, { asType: "tool" });
    requestedOrder += 1;
  }
}

function summarizeAnthropicResponse(response: Record<string, unknown>): Record<string, unknown> {
  const blocks = Array.isArray(response.content) ? response.content : [];
  const tools = blocks.filter((block) => isRecord(block) && block.type === "tool_use");
  const text = blocks.filter((block) => isRecord(block) && block.type === "text");
  return {
    content_capture: "none",
    tool_count: tools.length,
    text_block_count: text.length,
    stop_reason: typeof response.stop_reason === "string" ? response.stop_reason : "unknown",
  };
}

function validatorObservationName(value: ValidatorObservation): string {
  if (value.validatorName === "tool-decode") return "validator.tool_decode";
  if (value.validatorName === "scope-permission") return "validator.scope_permission";
  return value.attemptKind === "repair"
    ? `validator.ir.repair.${value.repairCount ?? 0}`
    : "validator.ir.initial";
}

function summarizeArguments(input: Record<string, unknown>): Record<string, unknown> {
  const valueTypeCounts: Record<string, number> = {};
  for (const value of Object.values(input).slice(0, 40)) {
    const kind = valueKind(value);
    valueTypeCounts[kind] = (valueTypeCounts[kind] ?? 0) + 1;
  }
  return {
    content_capture: "none",
    argument_count: Math.min(Object.keys(input).length, 40),
    value_type_counts: valueTypeCounts,
  };
}

function sanitizeArgumentSummary(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) return { content_capture: "none", argument_count: 0, value_type_counts: {} };
  const typeCounts = isRecord(value.valueTypeCounts) ? value.valueTypeCounts : {};
  const allowedTypes = ["string", "number", "boolean", "array", "object", "null", "other"];
  const valueTypeCounts = Object.fromEntries(allowedTypes.flatMap((type) => {
    const count = nonnegativeNumber(typeCounts[type]);
    return count === undefined ? [] : [[type, Math.min(Math.trunc(count), 40)]];
  }));
  return {
    content_capture: "none",
    argument_count: boundedInteger(value.argumentCount, 0, 40),
    value_type_counts: valueTypeCounts,
  };
}

function sanitizeResultSummary(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) {
    return { content_capture: "none", text_bytes: 0, has_decision: false, has_plan: false };
  }
  return {
    content_capture: "none",
    text_bytes: boundedInteger(value.textBytes, 0, 1_000_000),
    has_decision: value.hasDecision === true,
    has_plan: value.hasPlan === true,
  };
}

function sanitizeExportValue(value: unknown, key?: string): unknown {
  if (value === null) return value;
  if (typeof value === "boolean" || typeof value === "number") {
    return key && SAFE_METADATA_KEYS.has(key) ? value : "[REDACTED]";
  }
  if (typeof value === "string") {
    return key && SAFE_METADATA_KEYS.has(key) && safeCode(value) ? value : "[REDACTED]";
  }
  if (Array.isArray(value)) return value.slice(0, 100).map((item) => sanitizeExportValue(item, key));
  if (isRecord(value)) {
    return Object.fromEntries(Object.entries(value).slice(0, 100).map(([childKey, child]) => [
      childKey.slice(0, 100), sanitizeExportValue(child, childKey),
    ]));
  }
  return "[REDACTED]";
}

function safeMetadata(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([, child]) => child !== undefined));
}

function propagationMetadata(value: Record<string, unknown>): Record<string, string> {
  return Object.fromEntries(Object.entries(value).flatMap(([key, child]) => {
    if (typeof child === "string") return [[key, child.slice(0, 200)]];
    if (typeof child === "number" || typeof child === "boolean") return [[key, `${child}`]];
    return [];
  }));
}

function privateHash(value: string): string {
  return contentHashKey
    ? createHmac("sha256", contentHashKey).update(value).digest("hex")
    : createHash("sha256").update(value).digest("hex");
}

function pseudonymousUserID(uid: string): string {
  return `usr_${privateHash(`baseline-langfuse-user-v1:${uid}`).slice(0, 32)}`;
}

function deploymentEnvironment(): string {
  const explicit = process.env.BASELINE_ENVIRONMENT?.toLowerCase();
  if (explicit && /^[a-z0-9-_]{1,40}$/.test(explicit)) return explicit;
  const project = (process.env.GCLOUD_PROJECT ?? process.env.GOOGLE_CLOUD_PROJECT ?? "").toLowerCase();
  if (project.includes("prod")) return "production";
  if (project.includes("stag") || project.includes("dev")) return "staging";
  return process.env.NODE_ENV === "production" ? "production" : "development";
}

function functionRevision(): string {
  return bounded(process.env.K_REVISION ?? process.env.FUNCTION_TARGET ?? "local");
}

function randomSpanID(): string {
  let value = randomBytes(8).toString("hex");
  if (value === "0000000000000000") value = "0000000000000001";
  return value;
}

function bounded(value: string): string { return value.slice(0, 200); }

function boundedInteger(value: unknown, minimum: number, maximum: number): number {
  const number = typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : minimum;
  return Math.max(minimum, Math.min(number, maximum));
}

function boundedMilliseconds(value: number): number {
  return Math.max(0, Math.min(value, 600_000));
}

function nonnegativeNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

function safeCode(value: string): boolean {
  return /^[a-z0-9_./:@+-]{1,200}$/i.test(value);
}

function errorName(error: unknown): string {
  return error instanceof Error && error.name ? bounded(error.name) : "UnknownError";
}

function logInstrumentationFailure(stage: string, error?: unknown): void {
  logger.warn("llm_observability_instrumentation_failed", {
    stage,
    ...(error === undefined ? {} : { errorType: errorName(error) }),
  });
}

function errorStatus(error: unknown): number | undefined {
  if (!isRecord(error)) return undefined;
  return nonnegativeNumber(error.status) ?? nonnegativeNumber(error.statusCode);
}

/**
 * The provider's structured error fields, bounded for export. Before this existed, a provider
 * rejection recorded only the error class name: the 2026-07 top-level-oneOf 400 would have shown a
 * 100% `provider_failed` cliff in Langfuse without the message that named the offending schema
 * path. `code` is Anthropic's `error.type` (e.g. `invalid_request_error`); `message` is the first
 * 200 characters of `error.message`, which describes the request shape.
 *
 * Privacy: the message is pre-collapsed to the masker's `safeCode` charset (runs of anything else
 * become one `_`) and hard-capped, so even in the unlikely case a provider echoed request content
 * into an error message, only a short mangled shape descriptor could ever leave the function; the
 * export masker independently redacts any value that escapes that charset.
 */
export function providerErrorDetail(error: unknown): { code?: string; message?: string } {
  if (!isRecord(error)) return {};
  // @anthropic-ai/sdk APIError.error is the parsed body: { type: "error", error: { type, message } }.
  const body = isRecord(error.error) ? error.error : undefined;
  const inner = body && isRecord(body.error) ? body.error : body;
  if (!inner) return {};
  const code = typeof inner.type === "string" && inner.type !== "error" && safeCode(inner.type)
    ? bounded(inner.type)
    : undefined;
  const message = typeof inner.message === "string"
    ? sanitizedProviderErrorMessage(inner.message)
    : undefined;
  return { ...(code === undefined ? {} : { code }), ...(message === undefined ? {} : { message }) };
}

function sanitizedProviderErrorMessage(message: string): string | undefined {
  const collapsed = message
    .slice(0, 400)
    .replace(/[^a-zA-Z0-9_./:@+-]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 200);
  return collapsed.length > 0 ? collapsed : undefined;
}

function isRetryableProviderError(error: unknown): boolean {
  const status = errorStatus(error);
  return status === undefined || status === 408 || status === 409 || status === 429 || status >= 500;
}

function valueKind(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value === "object" ? "object" : typeof value;
}

function safeJSONString(value: unknown): string {
  try { return JSON.stringify(value) ?? "null"; } catch { return "unserializable"; }
}

function stableJSONString(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSONString).join(",")}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJSONString(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
