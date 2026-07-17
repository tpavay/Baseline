import { createHash, randomUUID } from "node:crypto";

import {
  ParsedWorkoutDocument,
  WorkoutDocumentValidationDiagnostic,
  assembleWorkoutImportIR,
  assembleWorkoutImportSectionDocuments,
  buildWorkoutImportRepairRequest,
  createWorkoutImportProviderAliasBoundary,
  expandWorkoutImportProvenance,
  reconcileParsedWorkoutCatalogIdentities,
  workoutDocumentValidationDiagnostic,
  workoutImportValidationLogFields,
  workoutImportTokenBudget,
  WORKOUT_IMPORT_MAX_OUTPUT_TOKENS,
} from "./workoutImport";
import {
  StartWorkoutImportJobPayload,
  StoredWorkoutImportJob,
  StoredWorkoutImportSection,
  WorkoutImportFailureCode,
  MAX_JOB_OUTPUT_TOKENS,
  MAX_JOB_PROVIDER_CALLS,
  MAX_RESULT_ENCODED_BYTES,
  MAX_SECTION_ATTEMPTS,
  MAX_SECTION_REPAIR_ATTEMPTS,
  assertEncodedSize,
  boundedRawIR,
  encodedJSONByteCount,
  isTerminalWorkoutImportFailure,
  isTerminalWorkoutImportJob,
  mapWithConcurrency,
  observationIDs,
  sectionPayload,
  workoutImportOperationalLog,
} from "./workoutImportJobs";

export interface WorkoutImportJobPublicStatus {
  serverJobID: string;
  status: StoredWorkoutImportJob["status"];
  completedSections: number;
  totalSections: number;
  document?: ParsedWorkoutDocument;
  model?: string;
  failureCode?: WorkoutImportFailureCode;
}

export interface WorkoutImportJobCommand {
  serverJobID: string;
  requestID?: string;
}

export interface WorkoutImportWorkerClaim {
  status: "acquired";
  job: StoredWorkoutImportJob;
  workerLeaseToken: string;
}

export interface WorkoutImportWorkerBusy {
  status: "busy";
}

export interface WorkoutImportSectionClaim {
  section: StoredWorkoutImportSection;
  claimToken: string;
}

export type WorkoutImportProviderReservation = "reserved" | "budget_exhausted" | "stale";

export interface WorkoutImportJobStore {
  createOrGet(
    uid: string,
    payload: StartWorkoutImportJobPayload,
    model: string,
  ): Promise<{ job: StoredWorkoutImportJob; created: boolean }>;
  getOwned(jobID: string, uid: string): Promise<StoredWorkoutImportJob>;
  recoverDispatch(jobID: string, generation: number): Promise<StoredWorkoutImportJob | undefined>;
  markDispatched(
    jobID: string,
    generation: number,
    dispatchAttempt: number,
  ): Promise<StoredWorkoutImportJob | undefined>;
  retry(jobID: string, uid: string, requestID: string): Promise<StoredWorkoutImportJob>;
  cancel(jobID: string, uid: string, requestID: string): Promise<StoredWorkoutImportJob | undefined>;
  acquireWorker(
    jobID: string,
    generation: number,
    dispatchAttempt: number,
    leaseToken: string,
  ): Promise<WorkoutImportWorkerClaim | WorkoutImportWorkerBusy | undefined>;
  heartbeatWorker(jobID: string, generation: number, leaseToken: string): Promise<boolean>;
  releaseWorker(
    jobID: string,
    generation: number,
    leaseToken: string,
  ): Promise<StoredWorkoutImportJob | undefined>;
  sections(jobID: string, generation: number): Promise<StoredWorkoutImportSection[]>;
  claimSection(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
  ): Promise<WorkoutImportSectionClaim | undefined>;
  reserveProviderCall(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    outputTokens: number,
  ): Promise<WorkoutImportProviderReservation>;
  saveRepairState(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    repairInput: unknown,
    diagnostic: WorkoutDocumentValidationDiagnostic,
  ): Promise<boolean>;
  completeSection(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    document: ParsedWorkoutDocument,
    repaired: boolean,
  ): Promise<boolean>;
  failSection(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    failureCode: WorkoutImportFailureCode,
    terminal: boolean,
  ): Promise<boolean>;
  completeJob(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    document: ParsedWorkoutDocument,
  ): Promise<boolean>;
  failJob(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    failureCode: WorkoutImportFailureCode,
  ): Promise<boolean>;
}

export interface WorkoutImportTaskQueue {
  enqueue(
    payload: { serverJobID: string; generation: number; dispatchAttempt: number },
    deterministicID: string,
  ): Promise<void>;
}

export interface WorkoutImportProvider {
  request(content: string, maxTokens: number): Promise<unknown>;
}

export interface WorkoutImportRuntimeLogger {
  info(event: string, fields: Record<string, string | number>): void;
  warn(event: string, fields: Record<string, string | number>): void;
}

export interface WorkoutImportJobRuntimeDependencies {
  store: WorkoutImportJobStore;
  queue: WorkoutImportTaskQueue;
  provider: WorkoutImportProvider;
  logger: WorkoutImportRuntimeLogger;
  randomID?: () => string;
  now?: () => number;
}

class StaleWorkoutImportClaim extends Error {
  constructor() { super("stale_workout_import_claim"); }
}

class RetryableWorkoutImportFailure extends Error {}

export class WorkoutImportProviderOutputTruncated extends Error {
  constructor() { super("provider_output_truncated"); }
}

type ClaimResult = "completed" | "retryable" | "terminal" | "stale";

const WORKOUT_IMPORT_FALLBACK_AMBIGUITY =
  "Baseline preserved the recognized text because this section could not be structured automatically. Review it and add or correct exercises before saving.";

function fallbackObservationNotes(section: Pick<StoredWorkoutImportSection, "observations">): string[] {
  const notes: string[] = [];
  let current = "";
  for (const observation of section.observations) {
    const line = observation.text.trim();
    if (!line) continue;
    const candidate = current ? `${current}\n${line}` : line;
    if (candidate.length <= 3_500) {
      current = candidate;
      continue;
    }
    if (current) notes.push(current);
    current = line;
  }
  if (current) notes.push(current);
  return notes;
}

/** Produces a provider-independent draft that preserves OCR without inventing exercises. */
export function buildWorkoutImportFallbackSectionDocument(
  section: Pick<StoredWorkoutImportSection, "order" | "observations">,
): ParsedWorkoutDocument {
  const sourceObservationIDs = section.observations.map((observation) => observation.id);
  return {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: `Imported section ${section.order + 1}`,
      notes: [],
      nodes: [{
        type: "group",
        group: {
          label: "Recognized text - needs review",
          adjustments: [],
          children: [],
          notes: fallbackObservationNotes(section),
          isOptional: false,
          ambiguity: WORKOUT_IMPORT_FALLBACK_AMBIGUITY,
          sourceObservationIDs,
        },
      }],
      sourceObservationIDs,
    }],
  };
}

function buildWorkoutImportFallbackJobDocument(
  sections: StoredWorkoutImportSection[],
  reasonCode: WorkoutImportFailureCode,
): ParsedWorkoutDocument {
  const documents = sections.map((section) =>
    reasonCode !== "result_too_large" && section.result
      ? expandWorkoutImportProvenance(section.result, section.provenance)
      : buildWorkoutImportFallbackSectionDocument(section));
  const sourceObservationIDs = sections.flatMap((section) =>
    section.observations.map((observation) => observation.id));
  const blocks = documents.flatMap((document) => structuredClone(document.blocks));
  blocks.push({
    name: "Import review",
    notes: [],
    nodes: [{
      type: "group",
      group: {
        label: "Check imported section boundaries",
        adjustments: [],
        children: [],
        notes: [],
        isOptional: false,
        ambiguity: reasonCode === "result_too_large"
          ? "Baseline preserved the recognized workout text, but the fully structured result was too large. Review each imported section before saving."
          : "Baseline preserved each imported section, but could not confidently combine every section boundary. Review the workout order before saving.",
        sourceObservationIDs,
      },
    }],
    sourceObservationIDs,
  });
  return {
    title: documents.find((document) => document.title && document.title !== "Imported workout")?.title
      ?? "Imported workout",
    notes: documents.flatMap((document) => document.notes),
    blocks,
  };
}

export class WorkoutImportJobRuntime {
  private readonly randomID: () => string;
  private readonly now: () => number;

  constructor(private readonly dependencies: WorkoutImportJobRuntimeDependencies) {
    this.randomID = dependencies.randomID ?? randomUUID;
    this.now = dependencies.now ?? Date.now;
  }

  async start(uid: string, payload: StartWorkoutImportJobPayload, model: string): Promise<WorkoutImportJobPublicStatus> {
    const { job, created } = await this.dependencies.store.createOrGet(uid, payload, model);
    this.dependencies.logger.info("workout_import_job.accepted", workoutImportOperationalLog({
      jobID: job.clientJobID,
      stage: created ? "created" : "resumed",
      generation: job.generation,
      dispatchAttempt: job.dispatchAttempt,
      sections: job.totalSections,
      observations: payload.sections.reduce((sum, section) => sum + section.observations.length, 0),
      characters: payload.sections.reduce(
        (sum, section) => sum + section.observations.reduce((subtotal, item) => subtotal + item.text.length, 0),
        0,
      ),
      model: job.model,
    }));
    return publicWorkoutImportStatus(await this.dispatchIfNeeded(job));
  }

  async status(uid: string, jobID: string): Promise<WorkoutImportJobPublicStatus> {
    const job = await this.dependencies.store.getOwned(jobID, uid);
    return publicWorkoutImportStatus(await this.dispatchIfNeeded(job));
  }

  async retry(uid: string, command: Required<WorkoutImportJobCommand>): Promise<WorkoutImportJobPublicStatus> {
    const current = await this.dependencies.store.getOwned(command.serverJobID, uid);
    if (current.cancelled || current.status === "cancelled" || current.status === "completed" ||
        (current.status === "failed" && isTerminalWorkoutImportFailure(current.failureCode))) {
      return publicWorkoutImportStatus(current);
    }
    const job = current.status === "failed"
      ? await this.dependencies.store.retry(command.serverJobID, uid, command.requestID)
      : current;
    return publicWorkoutImportStatus(await this.dispatchIfNeeded(job));
  }

  async cancel(uid: string, command: Required<WorkoutImportJobCommand>): Promise<WorkoutImportJobPublicStatus> {
    const job = await this.dependencies.store.cancel(command.serverJobID, uid, command.requestID);
    this.dependencies.logger.info("workout_import_job.cancelled", workoutImportOperationalLog({
      jobID: command.serverJobID,
      stage: "cancelled",
      generation: job?.generation,
      completedSections: job?.completedSections ?? 0,
      sections: job?.totalSections ?? 0,
      model: job?.model,
    }));
    return job ? publicWorkoutImportStatus(job) : {
      serverJobID: command.serverJobID,
      status: "cancelled",
      completedSections: 0,
      totalSections: 0,
    };
  }

  async dispatch(serverJobID: string, generation: number): Promise<void> {
    const job = await this.dependencies.store.recoverDispatch(serverJobID, generation);
    if (!job || job.generation !== generation) return;
    await this.dispatchIfNeeded(job, false);
  }

  async process(serverJobID: string, generation: number, dispatchAttempt: number): Promise<void> {
    const workerLeaseToken = this.randomID();
    const acquisition = await this.dependencies.store.acquireWorker(
      serverJobID, generation, dispatchAttempt, workerLeaseToken,
    );
    if (!acquisition) return;
    if (acquisition.status === "busy") throw new RetryableWorkoutImportFailure("worker_busy");

    try {
      const startedAt = this.now();
      await this.requireWorkerHeartbeat(serverJobID, generation, workerLeaseToken);
      const sourceSections = await this.dependencies.store.sections(serverJobID, generation);
      this.dependencies.logger.info("workout_import_job.worker_started", workoutImportOperationalLog({
        jobID: serverJobID,
        stage: "processing",
        generation,
        dispatchAttempt,
        sections: sourceSections.length,
        completedSections: sourceSections.filter((section) => section.status === "completed").length,
        model: acquisition.job.model,
      }));
      const incomplete = sourceSections.filter((section) => section.status !== "completed");
      const results = await mapWithConcurrency(incomplete, 2, async (candidate): Promise<ClaimResult> => {
        const claimToken = this.randomID();
        const claim = await this.dependencies.store.claimSection(
          serverJobID, generation, workerLeaseToken, candidate.id, claimToken,
        );
        if (!claim) return "stale";
        return this.processClaim(acquisition.job, workerLeaseToken, claim);
      });
      if (results.includes("stale")) throw new StaleWorkoutImportClaim();
      if (results.includes("retryable")) throw new RetryableWorkoutImportFailure("provider_unavailable");
      if (results.includes("terminal")) return;

      await this.requireWorkerHeartbeat(serverJobID, generation, workerLeaseToken);
      const completed = await this.dependencies.store.sections(serverJobID, generation);
      if (!completed.every((section) => section.status === "completed" && section.result)) {
        throw new RetryableWorkoutImportFailure("incomplete_sections");
      }

      let document: ParsedWorkoutDocument;
      try {
        document = assembleWorkoutImportSectionDocuments(
          completed.sort((left, right) => left.order - right.order).map((section) => ({
            sectionID: section.id,
            startScopeID: section.startScopeID,
            endScopeID: section.endScopeID,
            startObservationIDs: assemblyObservationIDs(section, false),
            endObservationIDs: assemblyObservationIDs(section, true),
            startFragmentPath: section.startFragmentPath,
            endFragmentPath: section.endFragmentPath,
            ...(section.continuationFromSectionID
              ? { continuationFromSectionID: section.continuationFromSectionID }
              : {}),
            document: expandWorkoutImportProvenance(section.result!, section.provenance),
          })),
          observationIDs(completed),
        );
        document = reconcileParsedWorkoutCatalogIdentities(
          document,
          completed.flatMap((section) => section.observations),
          acquisition.job.catalogHints,
        );
        assertEncodedSize(document, MAX_RESULT_ENCODED_BYTES, "result");
      } catch (error) {
        const failureCode: WorkoutImportFailureCode = sizeError(error)
          ? "result_too_large"
          : "cross_section_assembly";
        const fallback = buildWorkoutImportFallbackJobDocument(completed, failureCode);
        assertEncodedSize(fallback, MAX_RESULT_ENCODED_BYTES, "fallback_result");
        this.requireCAS(await this.dependencies.store.completeJob(
          serverJobID, generation, workerLeaseToken, fallback,
        ));
        this.dependencies.logger.warn("workout_import_job.assembly_fallback_completed", workoutImportOperationalLog({
          jobID: serverJobID,
          stage: "completed",
          generation,
          sections: completed.length,
          reasonCode: failureCode,
          model: acquisition.job.model,
        }));
        return;
      }

      await this.requireWorkerHeartbeat(serverJobID, generation, workerLeaseToken);
      this.requireCAS(await this.dependencies.store.completeJob(
        serverJobID, generation, workerLeaseToken, document,
      ));
      this.dependencies.logger.info("workout_import_job.completed", workoutImportOperationalLog({
        jobID: serverJobID,
        stage: "completed",
        generation,
        sections: completed.length,
        latencyMs: this.now() - startedAt,
        model: acquisition.job.model,
      }));
    } catch (error) {
      if (error instanceof StaleWorkoutImportClaim) return;
      if (schemaIncompatible(error)) {
        await this.dependencies.store.failJob(
          serverJobID, generation, workerLeaseToken, "schema_incompatible",
        );
        this.dependencies.logger.warn("workout_import_job.schema_incompatible", workoutImportOperationalLog({
          jobID: serverJobID,
          stage: "stored_schema",
          generation,
          model: acquisition.job.model,
          reasonCode: "schema_incompatible",
        }));
        return;
      }
      await this.dependencies.store.releaseWorker(serverJobID, generation, workerLeaseToken);
      throw error;
    }
  }

  private async processClaim(
    job: StoredWorkoutImportJob,
    workerLeaseToken: string,
    claim: WorkoutImportSectionClaim,
  ): Promise<ClaimResult> {
    const { section, claimToken } = claim;
    const payload = sectionPayload(section, job.catalogHints);
    const providerBoundary = createWorkoutImportProviderAliasBoundary(payload);
    const maxTokens = workoutImportTokenBudget(payload);

    const request = async (
      content: string,
      requestedTokens = maxTokens,
    ): Promise<{ value?: unknown; result?: ClaimResult }> => {
      let outputTokens = requestedTokens;
      let localAttempt = 0;
      while (true) {
        localAttempt += 1;
        const reservation = await this.dependencies.store.reserveProviderCall(
          job.clientJobID, job.generation, workerLeaseToken, section.id, claimToken, outputTokens,
        );
        if (reservation === "stale") throw new StaleWorkoutImportClaim();
        if (reservation === "budget_exhausted") {
          return { result: await this.persistFallback(
            job, section, workerLeaseToken, claimToken, "worker_budget_exhausted",
          ) };
        }
        const providerStartedAt = this.now();
        const requestBytes = Buffer.byteLength(content, "utf8");
        const attempt = section.providerCalls + localAttempt;
        try {
          const value = await this.dependencies.provider.request(content, outputTokens);
          this.dependencies.logger.info("workout_import_job.provider_attempt_completed", workoutImportOperationalLog({
            jobID: job.clientJobID,
            stage: "provider",
            generation: job.generation,
            attempt,
            latencyMs: this.now() - providerStartedAt,
            requestBytes,
            responseBytes: encodedJSONByteCount(value),
            outputTokens,
            model: job.model,
          }));
          return { value };
        } catch (error) {
          if (error instanceof WorkoutImportProviderOutputTruncated) {
            if (outputTokens < WORKOUT_IMPORT_MAX_OUTPUT_TOKENS) {
              this.dependencies.logger.warn("workout_import_job.output_truncated", workoutImportOperationalLog({
                jobID: job.clientJobID,
                stage: "section",
                generation: job.generation,
                attempt,
                latencyMs: this.now() - providerStartedAt,
                requestBytes,
                outputTokens,
                reasonCode: "provider_output_truncated",
                model: job.model,
              }));
              outputTokens = WORKOUT_IMPORT_MAX_OUTPUT_TOKENS;
              continue;
            }
            return { result: await this.persistFallback(
              job, section, workerLeaseToken, claimToken, "result_too_large",
            ) };
          }
          this.dependencies.logger.warn("workout_import_job.provider_attempt_failed", workoutImportOperationalLog({
            jobID: job.clientJobID,
            stage: "section",
            generation: job.generation,
            attempt,
            latencyMs: this.now() - providerStartedAt,
            requestBytes,
            outputTokens,
            reasonCode: providerFailureReason(error),
            model: job.model,
          }));
          const terminal = section.attempts + 1 >= MAX_SECTION_ATTEMPTS;
          if (terminal) {
            return { result: await this.persistFallback(
              job, section, workerLeaseToken, claimToken, "provider_unavailable",
            ) };
          }
          return { result: await this.failClaim(job, section, workerLeaseToken, claimToken,
            "provider_unavailable", false) };
        }
      }
    };

    try {
      const validateRepairLoop = async (
        candidate: unknown,
        completedRepairAttempts: number,
      ): Promise<ClaimResult> => {
        let raw = candidate;
        let repairAttempts = completedRepairAttempts;
        while (true) {
          const validation = this.validateIR(raw, section, job.catalogHints);
          if (validation.document) {
            return this.persistCompleted(
              job, section, workerLeaseToken, claimToken,
              validation.document, repairAttempts > 0,
            );
          }

          const invalidIR = boundedRawIR(raw);
          if (validation.diagnostic) {
            this.dependencies.logger.warn("workout_import_job.validation_failed", {
              ...workoutImportOperationalLog({
                jobID: job.clientJobID,
                stage: "section",
                generation: job.generation,
                reasonCode: validation.diagnostic.code,
                model: job.model,
              }),
              ...workoutImportValidationLogFields(
                repairAttempts === 0 ? "initial" : "repair",
                validation.diagnostic,
              ),
              repairAttempt: repairAttempts,
              classifierVersion: 2,
            });
          }
          if (!validation.diagnostic || !invalidIR ||
              repairAttempts >= MAX_SECTION_REPAIR_ATTEMPTS) {
            return this.persistFallback(
              job, section, workerLeaseToken, claimToken, "section_invalid",
            );
          }

          this.requireCAS(await this.dependencies.store.saveRepairState(
            job.clientJobID, job.generation, workerLeaseToken,
            section.id, claimToken, invalidIR, validation.diagnostic,
          ));
          repairAttempts += 1;
          const repaired = await request(
            buildWorkoutImportRepairRequest(
              providerBoundary.payload,
              providerBoundary.compactIR(invalidIR),
              providerBoundary.compactDiagnostic(validation.diagnostic),
            ),
            WORKOUT_IMPORT_MAX_OUTPUT_TOKENS,
          );
          if (repaired.result) return repaired.result;
          raw = providerBoundary.expandIR(repaired.value);
        }
      };

      if (section.repairInput && section.repairDiagnostic) {
        const response = await request(buildWorkoutImportRepairRequest(
          providerBoundary.payload, providerBoundary.compactIR(section.repairInput),
          providerBoundary.compactDiagnostic(
            section.repairDiagnostic as unknown as WorkoutDocumentValidationDiagnostic,
          ),
        ), WORKOUT_IMPORT_MAX_OUTPUT_TOKENS);
        if (response.result) return response.result;
        return await validateRepairLoop(
          providerBoundary.expandIR(response.value), section.repairAttempts,
        );
      }

      const initial = await request(JSON.stringify(providerBoundary.payload));
      if (initial.result) return initial.result;
      return await validateRepairLoop(providerBoundary.expandIR(initial.value), 0);
    } catch (error) {
      if (error instanceof StaleWorkoutImportClaim) return "stale";
      throw error;
    }
  }

  private validateIR(
    raw: unknown,
    section: StoredWorkoutImportSection,
    catalogHints: string[],
  ): { document?: ParsedWorkoutDocument; diagnostic?: WorkoutDocumentValidationDiagnostic } {
    try {
      const startPath = section.startFragmentPath ?? [section.startScopeID];
      const endPath = section.endFragmentPath ?? [section.endScopeID];
      const isContinuation = Boolean(section.continuationFromSectionID);
      const sameScope = startPath.length === endPath.length &&
        startPath.every((value, index) => value === endPath[index]);
      return {
        document: assembleWorkoutImportIR(
          raw,
          new Set(section.observations.map((observation) => observation.id)),
          {
            allowEmptyExercises: true,
            fallbackObservations: section.observations,
            continuationDepth: isContinuation ? Math.max(0, startPath.length - 1) : 0,
            catalogHints,
            ...(isContinuation
              ? { fallbackScope: sameScope ? "continuation" as const : "separateBlock" as const }
              : { fallbackScope: "workout" as const }),
          },
        ),
      };
    } catch (error) {
      return { diagnostic: workoutDocumentValidationDiagnostic(error) };
    }
  }

  private async persistCompleted(
    job: StoredWorkoutImportJob,
    section: StoredWorkoutImportSection,
    workerLeaseToken: string,
    claimToken: string,
    document: ParsedWorkoutDocument,
    repaired: boolean,
  ): Promise<ClaimResult> {
    try {
      this.requireCAS(await this.dependencies.store.completeSection(
        job.clientJobID, job.generation, workerLeaseToken,
        section.id, claimToken, document, repaired,
      ));
      return "completed";
    } catch (error) {
      if (!sizeError(error)) throw error;
      return this.persistFallback(
        job, section, workerLeaseToken, claimToken, "result_too_large",
      );
    }
  }

  private async persistFallback(
    job: StoredWorkoutImportJob,
    section: StoredWorkoutImportSection,
    workerLeaseToken: string,
    claimToken: string,
    reasonCode: WorkoutImportFailureCode,
  ): Promise<ClaimResult> {
    const document = buildWorkoutImportFallbackSectionDocument(section);
    this.requireCAS(await this.dependencies.store.completeSection(
      job.clientJobID,
      job.generation,
      workerLeaseToken,
      section.id,
      claimToken,
      document,
      true,
    ));
    this.dependencies.logger.warn("workout_import_job.section_fallback_completed", workoutImportOperationalLog({
      jobID: job.clientJobID,
      stage: "section",
      generation: job.generation,
      attempt: reasonCode === "provider_unavailable" ? section.attempts + 1 : section.attempts,
      reasonCode,
      model: job.model,
    }));
    return "completed";
  }

  private async failClaim(
    job: StoredWorkoutImportJob,
    section: StoredWorkoutImportSection,
    workerLeaseToken: string,
    claimToken: string,
    failureCode: WorkoutImportFailureCode,
    terminal: boolean,
  ): Promise<ClaimResult> {
    this.requireCAS(await this.dependencies.store.failSection(
      job.clientJobID, job.generation, workerLeaseToken,
      section.id, claimToken, failureCode, terminal,
    ));
    this.dependencies.logger.warn("workout_import_job.section_failed", workoutImportOperationalLog({
      jobID: job.clientJobID,
      stage: "section",
      generation: job.generation,
      attempt: failureCode === "provider_unavailable" ? section.attempts + 1 : section.attempts,
      reasonCode: failureCode,
      model: job.model,
    }));
    return terminal ? "terminal" : "retryable";
  }

  private async dispatchIfNeeded(
    initial: StoredWorkoutImportJob,
    tolerateQueueFailure = true,
  ): Promise<StoredWorkoutImportJob> {
    const recovered = await this.dependencies.store.recoverDispatch(initial.clientJobID, initial.generation);
    const job = recovered ?? initial;
    if (job.dispatchState !== "needsDispatch" || isTerminalWorkoutImportJob(job)) return job;
    const taskID = createHash("sha256")
      .update(`${job.clientJobID}:${job.generation}:${job.dispatchAttempt}`)
      .digest("hex")
      .slice(0, 32);
    try {
      await this.dependencies.queue.enqueue(
        {
          serverJobID: job.clientJobID,
          generation: job.generation,
          dispatchAttempt: job.dispatchAttempt,
        },
        taskID,
      );
    } catch {
      this.dependencies.logger.warn("workout_import_job.dispatch_failed", workoutImportOperationalLog({
        jobID: job.clientJobID,
        stage: "dispatch",
        generation: job.generation,
        dispatchAttempt: job.dispatchAttempt,
        reasonCode: "queue_unavailable",
        model: job.model,
      }));
      if (!tolerateQueueFailure) throw new RetryableWorkoutImportFailure("queue_unavailable");
      return job;
    }
    return await this.dependencies.store.markDispatched(
      job.clientJobID, job.generation, job.dispatchAttempt,
    ) ?? job;
  }

  private async requireWorkerHeartbeat(jobID: string, generation: number, token: string): Promise<void> {
    this.requireCAS(await this.dependencies.store.heartbeatWorker(jobID, generation, token));
  }

  private requireCAS(value: boolean): void {
    if (!value) throw new StaleWorkoutImportClaim();
  }
}

function providerFailureReason(error: unknown): string {
  if (!(error instanceof Error)) return "provider_unavailable";
  const status = (error as Error & { status?: unknown }).status;
  if (status === 429) return "provider_rate_limited";
  if (status === 408) return "provider_timeout";
  if (typeof status === "number" && status >= 500 && status <= 599) return "provider_5xx";
  if (/timeout/i.test(error.name) || /timed?\s*out/i.test(error.message)) return "provider_timeout";
  if (/connection/i.test(error.name)) return "provider_connection";
  if (error.message === "missing_tool_output") return "missing_tool_output";
  return "provider_unavailable";
}

export function publicWorkoutImportStatus(job: StoredWorkoutImportJob): WorkoutImportJobPublicStatus {
  return {
    serverJobID: job.clientJobID,
    status: job.status,
    completedSections: job.completedSections,
    totalSections: job.totalSections,
    ...(job.status === "completed" && job.document ? { document: job.document } : {}),
    ...(job.model ? { model: job.model } : {}),
    ...(job.failureCode ? { failureCode: job.failureCode } : {}),
  };
}

export function withinWorkoutImportJobBudget(job: StoredWorkoutImportJob, requestedTokens: number): boolean {
  return job.providerCalls < MAX_JOB_PROVIDER_CALLS &&
    job.outputTokensReserved + requestedTokens <= Math.min(job.outputTokenBudget, MAX_JOB_OUTPUT_TOKENS);
}

function sizeError(error: unknown): boolean {
  return error instanceof Error && error.message.includes("_too_large:");
}

function assemblyObservationIDs(
  section: StoredWorkoutImportSection,
  reverse: boolean,
): string[] {
  const sourceIDs = new Map(
    section.provenance.map((entry) => [entry.primaryID, entry.sourceObservationIDs]),
  );
  const observations = reverse ? [...section.observations].reverse() : section.observations;
  return [...new Set(observations.flatMap((observation) =>
    sourceIDs.get(observation.id) ?? [observation.id],
  ))];
}

function schemaIncompatible(error: unknown): boolean {
  return error instanceof Error &&
    (error as Error & { code?: unknown }).code === "failed-precondition";
}
